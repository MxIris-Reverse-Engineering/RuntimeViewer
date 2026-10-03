public import Foundation
import Synchronization

/// Where `RuntimeDeviceSuspensionController` gets its assertions.
///
/// A seam, not an abstraction for its own sake: the controller's job is the
/// reference counting and the release ordering, and that is what has to be
/// tested. Going through RunningBoard to test it would mean no test at all on
/// the platform that has a test runner.
public protocol RuntimeDeviceSuspensionAssertionProviding: Sendable {
    func assertion(
        preventingSuspensionOfProcessWithIdentifier processIdentifier: pid_t,
        explanation: String,
    ) throws -> any RuntimeDeviceSuspensionAssertionHolding
}

/// The live provider: a real RunningBoard assertion.
public struct RuntimeDeviceRunningBoardAssertionProvider: RuntimeDeviceSuspensionAssertionProviding {
    public init() {}

    public func assertion(
        preventingSuspensionOfProcessWithIdentifier processIdentifier: pid_t,
        explanation: String,
    ) throws -> any RuntimeDeviceSuspensionAssertionHolding {
        try RuntimeDeviceSuspensionAssertion.preventingSuspension(
            ofProcessWithIdentifier: processIdentifier,
            explanation: explanation,
        )
    }
}

/// Keeps the processes Runtime Viewer is using awake, one assertion per
/// process, for as long as anything still needs them.
///
/// **Why a reference count rather than one assertion per engine.** An injected
/// engine disconnects and reconnects as a matter of course — the variant is
/// suspended when it leaves the foreground, and its engines come back on their
/// own when it returns. If the assertion went away with the engine, the target
/// would be suspended the moment the connection dropped, and the reconnection
/// that is supposed to follow could never complete: there would be no thread
/// scheduled in the target to answer it. So the promise outlives any one
/// connection and ends only when the user detaches, or when the target exits.
///
/// Not gated on iOS, although only the device variant has a RunningBoard to
/// talk to. The counting and the ordering are where the mistakes live, and this
/// is the side of the gate that can be tested — the same reason
/// `RuntimeDeviceProcessEnumerator` takes the injector's uid as a parameter
/// instead of reading it.
public final class RuntimeDeviceSuspensionController: Sendable {
    private struct Entry {
        let assertion: any RuntimeDeviceSuspensionAssertionHolding
        var referenceCount: Int
    }

    private let assertionProvider: any RuntimeDeviceSuspensionAssertionProviding

    /// Held across the provider call on purpose.
    ///
    /// Acquiring an assertion is a round trip to `runningboardd`, so this does
    /// block other processes' retains for its duration. That is the deliberate
    /// trade: the alternative — releasing the lock to acquire — lets two
    /// concurrent retains of the same process each acquire one, and the loser
    /// then has to be thrown away. With a handful of targets at a time, the
    /// simpler invariant is worth more than the parallelism. Do not "fix" this
    /// into a double-checked acquire.
    private let entriesByProcessIdentifier = Mutex<[pid_t: Entry]>([:])

    public init(
        assertionProvider: any RuntimeDeviceSuspensionAssertionProviding = RuntimeDeviceRunningBoardAssertionProvider(),
    ) {
        self.assertionProvider = assertionProvider
    }

    /// Takes a reference on a process staying awake, acquiring the assertion if
    /// this is the first one.
    ///
    /// Throws whatever the provider threw, and in that case takes **no**
    /// reference — a failed retain must not leave a count behind that a later
    /// release would decrement into looking satisfied.
    public func retainAwake(processWithIdentifier processIdentifier: pid_t, explanation: String) throws {
        try entriesByProcessIdentifier.withLock { entries in
            if var existing = entries[processIdentifier] {
                existing.referenceCount += 1
                entries[processIdentifier] = existing
                return
            }
            let assertion = try assertionProvider.assertion(
                preventingSuspensionOfProcessWithIdentifier: processIdentifier,
                explanation: explanation,
            )
            entries[processIdentifier] = Entry(assertion: assertion, referenceCount: 1)
        }
    }

    /// Drops a reference, releasing the assertion when it was the last one.
    ///
    /// A process that is not being kept awake is not an error: a detach for
    /// something that was never retained — a target injected by an older build,
    /// say — should do nothing rather than trap.
    public func releaseAwake(processWithIdentifier processIdentifier: pid_t) {
        let releasedAssertion: (any RuntimeDeviceSuspensionAssertionHolding)? = entriesByProcessIdentifier
            .withLock { entries in
                guard var existing = entries[processIdentifier] else { return nil }
                existing.referenceCount -= 1
                guard existing.referenceCount <= 0 else {
                    entries[processIdentifier] = existing
                    return nil
                }
                entries.removeValue(forKey: processIdentifier)
                return existing.assertion
            }
        // Invalidated outside the lock: this is the one call that reaches
        // RunningBoard without anything depending on the outcome, so there is
        // no reason to hold other processes up for it.
        releasedAssertion?.invalidate()
    }

    /// Whether this controller is currently keeping that process awake.
    public func isKeepingAwake(processWithIdentifier processIdentifier: pid_t) -> Bool {
        entriesByProcessIdentifier.withLock { $0[processIdentifier] != nil }
    }

    /// How many references are outstanding on that process. Zero when none.
    public func referenceCount(forProcessWithIdentifier processIdentifier: pid_t) -> Int {
        entriesByProcessIdentifier.withLock { $0[processIdentifier]?.referenceCount ?? 0 }
    }
}
