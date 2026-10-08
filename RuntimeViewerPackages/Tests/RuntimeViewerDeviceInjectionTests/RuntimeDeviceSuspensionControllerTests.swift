import Testing
import Foundation
@testable import RuntimeViewerDeviceInjection

/// Who keeps an injected process awake, and for how long.
///
/// This is the part of the suspension work that can go wrong quietly. The
/// assertion itself either works or reports why; the counting is where a
/// mistake shows up much later, as a target that was suspended while an engine
/// was still trying to reconnect to it — and on a device, with no test runner.
@Suite("Device suspension controller")
struct RuntimeDeviceSuspensionControllerTests {
    /// Records what the controller asked for, and whether what it was given was
    /// given back.
    ///
    /// `@unchecked Sendable` because the provider protocol is `Sendable` and
    /// these tests drive the controller from one thread; the counters need no
    /// synchronisation of their own.
    private final class RecordingAssertionProvider: RuntimeDeviceSuspensionAssertionProviding, @unchecked Sendable {
        final class Assertion: RuntimeDeviceSuspensionAssertionHolding {
            let processIdentifier: pid_t
            private(set) var invalidationCount = 0

            init(processIdentifier: pid_t) {
                self.processIdentifier = processIdentifier
            }

            func invalidate() {
                invalidationCount += 1
            }
        }

        private(set) var requestedProcessIdentifiers: [pid_t] = []
        private(set) var issuedAssertions: [Assertion] = []
        private(set) var requestedExplanations: [String] = []

        /// Set to refuse the next and every later request.
        var failure: (any Error)?

        func assertion(
            preventingSuspensionOfProcessWithIdentifier processIdentifier: pid_t,
            explanation: String,
        ) throws -> any RuntimeDeviceSuspensionAssertionHolding {
            requestedProcessIdentifiers.append(processIdentifier)
            requestedExplanations.append(explanation)
            if let failure {
                throw failure
            }
            let assertion = Assertion(processIdentifier: processIdentifier)
            issuedAssertions.append(assertion)
            return assertion
        }
    }

    private struct RefusedByRunningBoard: Error {}

    @Test("The first retain acquires one assertion")
    func firstRetainAcquires() throws {
        let provider = RecordingAssertionProvider()
        let controller = RuntimeDeviceSuspensionController(assertionProvider: provider)

        try controller.retainAwake(processWithIdentifier: 501, explanation: "injecting")

        #expect(provider.requestedProcessIdentifiers == [501])
        #expect(provider.requestedExplanations == ["injecting"])
        #expect(controller.isKeepingAwake(processWithIdentifier: 501))
        #expect(controller.referenceCount(forProcessWithIdentifier: 501) == 1)
    }

    /// Two engines on one process must not mean two assertions: RunningBoard
    /// would honour either, but then releasing one would look like releasing
    /// the promise.
    @Test("A second retain on the same process reuses the assertion")
    func secondRetainDoesNotAcquireAgain() throws {
        let provider = RecordingAssertionProvider()
        let controller = RuntimeDeviceSuspensionController(assertionProvider: provider)

        try controller.retainAwake(processWithIdentifier: 501, explanation: "first")
        try controller.retainAwake(processWithIdentifier: 501, explanation: "second")

        #expect(provider.issuedAssertions.count == 1)
        #expect(controller.referenceCount(forProcessWithIdentifier: 501) == 2)
    }

    @Test("Releasing one of two references keeps the process awake")
    func releasingOneOfTwoKeepsItAwake() throws {
        let provider = RecordingAssertionProvider()
        let controller = RuntimeDeviceSuspensionController(assertionProvider: provider)

        try controller.retainAwake(processWithIdentifier: 501, explanation: "first")
        try controller.retainAwake(processWithIdentifier: 501, explanation: "second")
        controller.releaseAwake(processWithIdentifier: 501)

        #expect(controller.isKeepingAwake(processWithIdentifier: 501))
        #expect(controller.referenceCount(forProcessWithIdentifier: 501) == 1)
        #expect(provider.issuedAssertions.first?.invalidationCount == 0)
    }

    @Test("Releasing the last reference invalidates the assertion and forgets the process")
    func releasingTheLastReferenceInvalidates() throws {
        let provider = RecordingAssertionProvider()
        let controller = RuntimeDeviceSuspensionController(assertionProvider: provider)

        try controller.retainAwake(processWithIdentifier: 501, explanation: "injecting")
        controller.releaseAwake(processWithIdentifier: 501)

        #expect(provider.issuedAssertions.first?.invalidationCount == 1)
        #expect(!controller.isKeepingAwake(processWithIdentifier: 501))
        #expect(controller.referenceCount(forProcessWithIdentifier: 501) == 0)
    }

    /// The failure mode this guards: a retain that threw but still counted
    /// would make the next release decrement to zero and report the process as
    /// no longer kept awake — when it never was. Worse, a *second* retain would
    /// then find an entry and skip acquiring, so the process would be reported
    /// awake while holding nothing at all.
    @Test("A refused retain leaves no reference behind")
    func refusedRetainLeavesNothing() throws {
        let provider = RecordingAssertionProvider()
        provider.failure = RefusedByRunningBoard()
        let controller = RuntimeDeviceSuspensionController(assertionProvider: provider)

        #expect(throws: RefusedByRunningBoard.self) {
            try controller.retainAwake(processWithIdentifier: 501, explanation: "injecting")
        }

        #expect(!controller.isKeepingAwake(processWithIdentifier: 501))
        #expect(controller.referenceCount(forProcessWithIdentifier: 501) == 0)

        // And the next retain really does try again, rather than finding a
        // phantom entry.
        provider.failure = nil
        try controller.retainAwake(processWithIdentifier: 501, explanation: "injecting")
        #expect(provider.issuedAssertions.count == 1)
        #expect(controller.referenceCount(forProcessWithIdentifier: 501) == 1)
    }

    /// A detach for a target this build never retained — one injected by an
    /// earlier build, say — has to do nothing rather than trap or go negative.
    @Test("Releasing a process that was never retained does nothing")
    func releasingAnUnknownProcessDoesNothing() {
        let provider = RecordingAssertionProvider()
        let controller = RuntimeDeviceSuspensionController(assertionProvider: provider)

        controller.releaseAwake(processWithIdentifier: 501)

        #expect(provider.issuedAssertions.isEmpty)
        #expect(controller.referenceCount(forProcessWithIdentifier: 501) == 0)
    }

    @Test("Each process gets its own assertion, released independently")
    func processesAreIndependent() throws {
        let provider = RecordingAssertionProvider()
        let controller = RuntimeDeviceSuspensionController(assertionProvider: provider)

        try controller.retainAwake(processWithIdentifier: 501, explanation: "one")
        try controller.retainAwake(processWithIdentifier: 502, explanation: "two")
        controller.releaseAwake(processWithIdentifier: 501)

        #expect(provider.issuedAssertions.count == 2)
        #expect(!controller.isKeepingAwake(processWithIdentifier: 501))
        #expect(controller.isKeepingAwake(processWithIdentifier: 502))
        let assertionForFirstProcess = provider.issuedAssertions.first { $0.processIdentifier == 501 }
        let assertionForSecondProcess = provider.issuedAssertions.first { $0.processIdentifier == 502 }
        #expect(assertionForFirstProcess?.invalidationCount == 1)
        #expect(assertionForSecondProcess?.invalidationCount == 0)
    }
}

/// That the Objective-C runtime lookup behind the assertions actually resolves.
///
/// Every class, selector and gate behind `RuntimeDeviceSuspensionAssertion` was
/// read out of an iOS 26.3.1 shared cache, and the device it runs on is 26.6.2 —
/// so "did the interface move" is a live question with no test runner to answer
/// it. macOS carries the same `RBS…` classes, which makes these two cases the
/// only automated check that the lookup, the protocol dispatch and the
/// three-argument construction all still work.
///
/// They deliberately do **not** tolerate the classes being absent. The whole
/// premise of `RuntimeViewerRunningBoardSupport` is that these classes exist and
/// answer these selectors; a test that shrugged at their absence would protect
/// nothing.
@Suite("RunningBoard runtime lookup")
struct RuntimeDeviceRunningBoardLookupTests {
    /// Asking about *this* process takes RunningBoard's dedicated path and needs
    /// no entitlement, so it exercises class lookup, handle and state end to end.
    @Test("This process reports itself as running")
    func thisProcessIsRunning() {
        let state = RuntimeDeviceRunningState.ofProcess(withIdentifier: getpid())
        if case .unknown(let reason) = state {
            Issue.record("RunningBoard did not answer for this process: \(reason)")
            return
        }
        #expect(state == .running)
    }

    /// Acquisition is expected to be *refused* here — a test binary carries no
    /// `com.apple.runningboard.primitiveattribute` — and that is the point: a
    /// refusal proves the call reached RunningBoard, which is what distinguishes
    /// a permission problem from a moved interface.
    @Test("Acquiring reaches RunningBoard rather than failing to find it")
    func acquisitionReachesRunningBoard() {
        do {
            let assertion = try RuntimeDeviceSuspensionAssertion.preventingSuspension(
                ofProcessWithIdentifier: getpid(),
                explanation: "Runtime Viewer test",
            )
            // Granted after all: give it straight back rather than leaving a
            // real assertion held for the rest of the test run.
            assertion.invalidate()
        } catch {
            // Typed throws makes `error` an `AcquisitionFailure` here, so this
            // switch is exhaustive where separate `catch` patterns are not.
            switch error {
            case .runningBoardUnavailable(let reason):
                Issue.record("The RunningBoard lookup itself failed, so the interface moved: \(reason)")
            case .refused:
                // The expected outcome, and a pass: it got far enough to be told no.
                break
            }
        }
    }
}
