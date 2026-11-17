import Foundation
@testable import RuntimeViewerCommunication

/// The system's socket calls, with the hooks the descriptor lifetime tests need:
/// `accept`s that fail before reaching the system, a step-in point after the
/// first `send`, a `close` that holds on until the next call, and a record of
/// every call made on a descriptor after it was closed.
///
/// A call on a closed descriptor never reaches the system. It fails with
/// `EBADF` instead, as it would once the number is free — before the system
/// hands the number to the next file the process opens, at which point the
/// same call reads or writes that file.
final class ScriptedSocketSystemCalls: RuntimeSocketSystemCalls, @unchecked Sendable {
    private let system = RuntimeDarwinSocketSystemCalls()
    private let lock = NSLock()

    private var acceptFailures: [Int32] = []
    private var acceptCallCount = 0
    private var closedDescriptors: Set<Int32> = []
    private var recordedCallsAfterClose: [String] = []
    private var hasSentOnce = false
    private var isHoldingFirstClose = false

    /// Signalled when a `close` is held, and handed to `onFirstSend`.
    private let stepInSemaphore = DispatchSemaphore(value: 0)
    /// Signalled by the first call made on a closed descriptor.
    private let callAfterCloseSemaphore = DispatchSemaphore(value: 0)

    /// Run after the first `send` has sent one byte, before it returns. It is
    /// handed a semaphore to signal once it has done what it steps in to do;
    /// a held `close` signals it too. The `send` waits for it, two seconds at
    /// most.
    var onFirstSend: (@Sendable (DispatchSemaphore) -> Void)? {
        get { withLock { _onFirstSend } }
        set { withLock { _onFirstSend = newValue } }
    }

    private var _onFirstSend: (@Sendable (DispatchSemaphore) -> Void)?

    /// Every call made on a descriptor after it was closed, as `name(descriptor)`.
    var callsAfterClose: [String] {
        withLock { recordedCallsAfterClose }
    }

    /// How many times `accept` was called, failed ones included.
    var acceptCalls: Int {
        withLock { acceptCallCount }
    }

    /// The next `accept`s fail with these errors, in order, without reaching
    /// the system.
    func failNextAccepts(with errorNumbers: [Int32]) {
        withLock { acceptFailures.append(contentsOf: errorNumbers) }
    }

    /// The first `close` marks its descriptor closed, then waits — a second at
    /// most — for another call to be made on it before it closes it for real:
    /// the window between `close` returning and a connection forgetting the
    /// descriptor's number, held open.
    func holdFirstCloseUntilNextCall() {
        withLock { isHoldingFirstClose = true }
    }

    // MARK: - RuntimeSocketSystemCalls

    func accept(_ socketDescriptor: Int32) -> Int32 {
        if let errorNumber = rejectIfClosed("accept", socketDescriptor) {
            errno = errorNumber
            return -1
        }
        let scriptedFailure: Int32? = withLock {
            acceptCallCount += 1
            return acceptFailures.isEmpty ? nil : acceptFailures.removeFirst()
        }
        if let scriptedFailure {
            errno = scriptedFailure
            return -1
        }
        return system.accept(socketDescriptor)
    }

    func receive(_ socketDescriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Int {
        if let errorNumber = rejectIfClosed("receive", socketDescriptor) {
            errno = errorNumber
            return -1
        }
        return system.receive(socketDescriptor, into: buffer)
    }

    func send(_ socketDescriptor: Int32, from buffer: UnsafeRawBufferPointer) -> Int {
        if let errorNumber = rejectIfClosed("send", socketDescriptor) {
            errno = errorNumber
            return -1
        }
        let stepIn: (@Sendable (DispatchSemaphore) -> Void)? = withLock {
            guard !hasSentOnce else { return nil }
            hasSentOnce = true
            return _onFirstSend
        }
        guard let stepIn, buffer.count > 1 else {
            return system.send(socketDescriptor, from: buffer)
        }
        let sent = system.send(socketDescriptor, from: UnsafeRawBufferPointer(rebasing: buffer.prefix(1)))
        stepIn(stepInSemaphore)
        _ = stepInSemaphore.wait(timeout: .now() + 2)
        return sent
    }

    func shutdown(_ socketDescriptor: Int32) {
        if rejectIfClosed("shutdown", socketDescriptor) != nil { return }
        system.shutdown(socketDescriptor)
    }

    func close(_ socketDescriptor: Int32) {
        if rejectIfClosed("close", socketDescriptor) != nil { return }
        let holds: Bool = withLock {
            closedDescriptors.insert(socketDescriptor)
            defer { isHoldingFirstClose = false }
            return isHoldingFirstClose
        }
        if holds {
            stepInSemaphore.signal()
            _ = callAfterCloseSemaphore.wait(timeout: .now() + 1)
        }
        system.close(socketDescriptor)
    }

    // MARK: - Private

    /// `EBADF` when `socketDescriptor` was closed already, after recording the call.
    private func rejectIfClosed(_ name: String, _ socketDescriptor: Int32) -> Int32? {
        let isClosed: Bool = withLock {
            guard closedDescriptors.contains(socketDescriptor) else { return false }
            recordedCallsAfterClose.append("\(name)(\(socketDescriptor))")
            return true
        }
        guard isClosed else { return nil }
        callAfterCloseSemaphore.signal()
        return EBADF
    }

    private func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
