import Testing
import Foundation
import RuntimeViewerCore
@testable import RuntimeViewerDeviceInjection

/// The enumerator ships only in the iOS variant, but it is built and tested
/// here: the BSD calls underneath are the same on macOS, so every rule in it is
/// exercised on a machine that has a test runner. The device has neither one
/// nor a way to fail a build, so an iOS-only implementation would have no
/// coverage at all.
@Suite("Device process enumerator")
struct RuntimeDeviceProcessEnumeratorTests {
    // MARK: - The pid set

    @Test("Lists processes, including this one")
    func listsOwnProcess() throws {
        let identifiers = try RuntimeDeviceProcessEnumerator.processIdentifiers()
        #expect(!identifiers.isEmpty)
        #expect(identifiers.contains(getpid()))
    }

    /// `proc_listallpids(nil, 0)` answers a capacity hint, not a count — an
    /// upper bound the kernel is willing to promise. Sizing the result from the
    /// hint instead of from the second call's return value reads the
    /// uninitialized tail of the buffer as pids, which show up as zeros.
    @Test("Does not report the uninitialized tail of its buffer as pids")
    func trailingEntriesAreNotReported() throws {
        let identifiers = try RuntimeDeviceProcessEnumerator.processIdentifiers()
        #expect(!identifiers.contains(0))
        #expect(identifiers.allSatisfy { $0 > 0 })
    }

    @Test("Every listed process keeps its identity through the model")
    func processListIsWellFormed() throws {
        let processes = try RuntimeDeviceProcessEnumerator.processList(injectorUserIdentifier: getuid())
        #expect(!processes.isEmpty)
        // pid 0 is the kernel and is filtered out, not described.
        #expect(processes.allSatisfy { $0.processIdentifier > 0 })
        // The name is a fallback chain, so it is never empty even when
        // `proc_name` and `proc_pidpath` both decline.
        #expect(processes.allSatisfy { !$0.name.isEmpty })
        // No duplicates: one row per pid.
        #expect(Set(processes.map(\.processIdentifier)).count == processes.count)
    }

    // MARK: - Reading one process

    @Test("Reads this process's own name and path")
    func readsOwnNameAndPath() {
        let ownIdentifier = getpid()
        let name = RuntimeDeviceProcessEnumerator.name(ofProcessWithIdentifier: ownIdentifier)
        let path = RuntimeDeviceProcessEnumerator.executablePath(ofProcessWithIdentifier: ownIdentifier)
        #expect(name != nil)
        #expect(path != nil)
        #expect(path?.hasPrefix("/") == true)
    }

    @Test("Reads this process's own uid")
    func readsOwnUserIdentifier() {
        #expect(RuntimeDeviceProcessEnumerator.userIdentifier(ofProcessWithIdentifier: getpid()) == getuid())
    }

    /// pid 1 is launchd on both platforms, and it is root on both.
    @Test("Reads launchd as root")
    func readsLaunchdAsRoot() {
        #expect(RuntimeDeviceProcessEnumerator.userIdentifier(ofProcessWithIdentifier: 1) == 0)
    }

    /// A pid that cannot exist must produce "could not tell", not a wrong
    /// answer — and in particular not uid 0, which is the value that means
    /// "root target, needs a root injector".
    @Test("Answers nil rather than zero for a pid that does not exist")
    func unknownProcessHasNoUserIdentifier() {
        let impossibleIdentifier: pid_t = .max
        #expect(RuntimeDeviceProcessEnumerator.userIdentifier(ofProcessWithIdentifier: impossibleIdentifier) == nil)
        #expect(RuntimeDeviceProcessEnumerator.name(ofProcessWithIdentifier: impossibleIdentifier) == nil)
        #expect(RuntimeDeviceProcessEnumerator.executablePath(ofProcessWithIdentifier: impossibleIdentifier) == nil)
    }

    // MARK: - Injectability

    /// Measured on iOS 26.6.2: a uid 501 process cannot obtain the task port of
    /// a uid 0 process however it is entitled.
    @Test("A root target needs a root injector")
    func rootTargetRequiresRootInjector() {
        let verdict = RuntimeDeviceProcessEnumerator.injectability(
            ofProcessWithIdentifier: 4321,
            userIdentifier: 0,
            injectorUserIdentifier: 501,
            ownProcessIdentifier: 99,
        )
        #expect(verdict == .requiresRootOnTarget)
    }

    @Test("A root injector may target a root process")
    func rootInjectorMayTargetRoot() {
        let verdict = RuntimeDeviceProcessEnumerator.injectability(
            ofProcessWithIdentifier: 4321,
            userIdentifier: 0,
            injectorUserIdentifier: 0,
            ownProcessIdentifier: 99,
        )
        #expect(verdict == .injectable)
    }

    /// The decision this test pins is the one that is easy to get backwards.
    /// An unreadable uid must *not* become a refusal: pre-screening exists to
    /// keep doomed targets out of the picker, and treating "unknown" as
    /// "impossible" would empty the list on any device where the uid lookup is
    /// not permitted. The injection attempt is the authority.
    @Test("An unknown owner stays injectable, so the attempt decides")
    func unknownOwnerStaysInjectable() {
        let verdict = RuntimeDeviceProcessEnumerator.injectability(
            ofProcessWithIdentifier: 4321,
            userIdentifier: nil,
            injectorUserIdentifier: 501,
            ownProcessIdentifier: 99,
        )
        #expect(verdict == .injectable)
    }

    @Test("This process is not a target for itself")
    func ownProcessIsNotInjectable() {
        let verdict = RuntimeDeviceProcessEnumerator.injectability(
            ofProcessWithIdentifier: 99,
            userIdentifier: 501,
            injectorUserIdentifier: 501,
            ownProcessIdentifier: 99,
        )
        #expect(verdict.isInjectable == false)
        if case .notInjectable = verdict {} else {
            Issue.record("Expected .notInjectable for our own pid, got \(verdict)")
        }
    }

    /// launchd is reported by name rather than as a bare "needs root", because
    /// it is the target a user is most likely to try and the general rule
    /// explains less than saying what it is. It also must not depend on the
    /// uid lookup succeeding.
    @Test("launchd is refused by identity, not by uid lookup")
    func launchdIsRefusedWithoutNeedingItsUserIdentifier() {
        let verdict = RuntimeDeviceProcessEnumerator.injectability(
            ofProcessWithIdentifier: 1,
            userIdentifier: nil,
            injectorUserIdentifier: 501,
            ownProcessIdentifier: 99,
        )
        if case .notInjectable(let reason) = verdict {
            #expect(reason.contains("launchd"))
        } else {
            Issue.record("Expected .notInjectable for pid 1, got \(verdict)")
        }
    }

    @Test("A live process from the real list carries a usable verdict")
    func realListCarriesVerdicts() throws {
        let processes = try RuntimeDeviceProcessEnumerator.processList(injectorUserIdentifier: getuid())
        let ownRow = processes.first { $0.processIdentifier == getpid() }
        #expect(ownRow != nil)
        #expect(ownRow?.injectability.isInjectable == false)

        if let launchdRow = processes.first(where: { $0.processIdentifier == 1 }) {
            #expect(launchdRow.injectability.isInjectable == false)
        }
    }
}
