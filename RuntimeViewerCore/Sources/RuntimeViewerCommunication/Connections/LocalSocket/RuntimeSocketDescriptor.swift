import Foundation
import FoundationToolbox

/// A socket descriptor that several threads use at once — one blocked in
/// `recv` or `accept`, another sending — and that any of them may invalidate.
///
/// Closing the descriptor while another thread can still be about to use its
/// number is the hazard this type exists for. Once closed, the system hands
/// the number to the next `open`, `socket` or `pipe` in the process, and a late
/// `recv` then reads that file's data, a late `send` writes into it and a late
/// `close` closes it. So invalidating only shuts the socket down — which wakes
/// every call blocked on it — and the descriptor is closed when the last call
/// in flight has returned, exactly once. No call starts once it is invalidated.
///
/// `@unchecked Sendable`: the descriptor and the system calls never change, and
/// the rest is behind a `Mutex`.
final class RuntimeSocketDescriptor: @unchecked Sendable {
    private struct State {
        var isInvalidated = false
        var callsInFlight = 0
    }

    private let socketDescriptor: Int32
    private let systemCalls: any RuntimeSocketSystemCalls
    private let state = Mutex(State())

    /// Takes ownership of `socketDescriptor`: it is closed through
    /// `systemCalls` once invalidated and no longer in use.
    init(_ socketDescriptor: Int32, systemCalls: any RuntimeSocketSystemCalls) {
        self.socketDescriptor = socketDescriptor
        self.systemCalls = systemCalls
    }

    /// Whether ``invalidate()`` has been called.
    var isInvalidated: Bool {
        state.withLock { $0.isInvalidated }
    }

    /// Runs `body` with the descriptor, which stays open until `body` returns;
    /// `nil` without running it once the descriptor is invalidated.
    ///
    /// `body` may block — in `recv`, `send` or `accept` — and is woken by
    /// ``invalidate()``, which shuts the socket down.
    func withDescriptor<Result>(_ body: (Int32) throws -> Result) rethrows -> Result? {
        let mayUse = state.withLock { current in
            guard !current.isInvalidated else { return false }
            current.callsInFlight += 1
            return true
        }
        guard mayUse else { return nil }
        defer { endCall() }
        return try body(socketDescriptor)
    }

    /// Shuts the socket down and closes it as soon as no call is using it.
    ///
    /// - Returns: `true` for the call that invalidated it, `false` for every
    ///   later one.
    @discardableResult
    func invalidate() -> Bool {
        // The shutdown counts as a call in flight, so that a call ending at the
        // same time cannot close the descriptor before it is shut down.
        let isFirst = state.withLock { current in
            guard !current.isInvalidated else { return false }
            current.isInvalidated = true
            current.callsInFlight += 1
            return true
        }
        guard isFirst else { return false }
        systemCalls.shutdown(socketDescriptor)
        endCall()
        return true
    }

    private func endCall() {
        let closes = state.withLock { current in
            current.callsInFlight -= 1
            return current.isInvalidated && current.callsInFlight == 0
        }
        if closes {
            systemCalls.close(socketDescriptor)
        }
    }
}
