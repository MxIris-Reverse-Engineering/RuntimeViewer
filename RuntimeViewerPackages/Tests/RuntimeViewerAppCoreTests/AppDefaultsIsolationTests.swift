import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// What `AppDefaults.isolated()` promises the suites that build one: a write
/// to one instance reaches no other, and none reaches the test process's
/// standard defaults.
///
/// The race these replace — a Find session rerunning its search because an
/// unrelated test changed the Generation Options, which lived in user
/// defaults then — cannot be reproduced on demand; these are its
/// deterministic stand-ins, written against the Match Case switch, a value
/// still kept there. Each writes a value that differs from what the instance
/// holds, so a leftover from an earlier run cannot hide a leak behind an
/// equal value.
@Suite("AppDefaults isolation")
struct AppDefaultsIsolationTests {
    @Test("a write stays in the instance it was made on")
    func writeStaysInItsInstance() {
        restoringStandardCaseSensitivity {
            let writer = AppDefaults.isolated()
            let bystander = AppDefaults.isolated()
            let bystanderValueBefore = bystander.isRuntimeObjectFilterCaseSensitive

            writer.isRuntimeObjectFilterCaseSensitive.toggle()

            #expect(bystander.isRuntimeObjectFilterCaseSensitive == bystanderValueBefore, "another instance's write changed what this one reads")
        }
    }

    @Test("another instance's write is not observed")
    func otherInstanceWriteIsNotObserved() {
        restoringStandardCaseSensitivity {
            let writer = AppDefaults.isolated()
            let bystander = AppDefaults.isolated()
            let writtenValue = !writer.isRuntimeObjectFilterCaseSensitive
            #expect(bystander.isRuntimeObjectFilterCaseSensitive != writtenValue, "both fresh instances start alike")
            var observedWrites: [Bool] = []
            let disposeBag = DisposeBag()
            bystander.$isRuntimeObjectFilterCaseSensitive
                .filter { value in value == writtenValue }
                .subscribeOnNext { value in observedWrites.append(value) }
                .disposed(by: disposeBag)

            // Key-value observation of a defaults key is delivered on the
            // writing thread, before the setter returns.
            writer.isRuntimeObjectFilterCaseSensitive = writtenValue

            #expect(observedWrites.isEmpty, "this instance's stream reported another instance's write")
            withExtendedLifetime(disposeBag) {}
        }
    }

    @Test("an isolated instance leaves the standard defaults alone")
    func isolatedInstanceLeavesStandardDefaultsAlone() {
        restoringStandardCaseSensitivity {
            let standardValueBefore = UserDefaults.standard.object(forKey: Self.caseSensitivityKey) as? Bool
            let isolated = AppDefaults.isolated()

            isolated.isRuntimeObjectFilterCaseSensitive.toggle()

            #expect(
                UserDefaults.standard.object(forKey: Self.caseSensitivityKey) as? Bool == standardValueBefore,
                "an isolated instance wrote the test process's standard defaults"
            )
        }
    }

    // MARK: - Nothing piles up across runs

    /// Every isolated namespace shares one suite, so what its owner leaves
    /// there stays for every later run unless the owner takes it away.
    @Test("a released isolated instance takes its values with it")
    func releasedInstanceTakesItsValuesWithIt() {
        let namespace = Self.namespaceOfReleasedInstance()

        #expect(namespace.isolatedKeys == [], "a released instance left values in the isolated suite")
    }

    /// What an owner that is never released leaves behind — the test
    /// fallback, a leaked view model, a crashed run — is swept by the next
    /// process, but only once the owner's process has ended: another test
    /// run going on at the same time keeps its values.
    @Test("the isolated suite is swept of ended processes' values, not of running ones'")
    func endedProcessesValuesAreSwept() {
        // No process can have this identifier: the system's are far smaller.
        let endedProcessNamespace = UserDefaultsNamespace.makeIsolated(owningProcessIdentifier: pid_t.max)
        let runningProcessNamespace = UserDefaultsNamespace.makeIsolated()
        let suite = runningProcessNamespace.userDefaults
        let endedProcessKey = endedProcessNamespace.key("generationOptions")
        let runningProcessKey = runningProcessNamespace.key("generationOptions")
        suite.set(Data(), forKey: endedProcessKey)
        suite.set(Data(), forKey: runningProcessKey)
        defer {
            suite.removeObject(forKey: endedProcessKey)
            suite.removeObject(forKey: runningProcessKey)
        }

        UserDefaultsNamespace.removeNamespacesOfEndedProcesses(in: suite)

        #expect(endedProcessNamespace.isolatedKeys == [], "an ended process's values were kept")
        #expect(runningProcessNamespace.isolatedKeys == [runningProcessKey], "a running process's values were swept")
    }

    // MARK: - Helpers

    /// Builds an isolated instance, gives it a value of its own, and lets it
    /// go when this returns.
    private static func namespaceOfReleasedInstance() -> UserDefaultsNamespace {
        let appDefaults = AppDefaults.isolated()
        appDefaults.isRuntimeObjectFilterCaseSensitive.toggle()
        #expect(appDefaults.userDefaultsNamespace.isolatedKeys?.isEmpty == false, "the write never reached the isolated suite")
        return appDefaults.userDefaultsNamespace
    }

    /// The key the app keeps the Match Case switch under in the standard
    /// defaults.
    private static let caseSensitivityKey = "runtimeObjectFilterIsCaseSensitive"

    /// Puts the test process's standard Match Case switch back if `body`
    /// changed it, which only a broken isolation does. Written only on a
    /// difference, so a passing run never touches the standard defaults; a
    /// failing one does not leave its write behind for the next run to read.
    private func restoringStandardCaseSensitivity(_ body: () -> Void) {
        let standardValueBefore = UserDefaults.standard.object(forKey: Self.caseSensitivityKey) as? Bool
        defer {
            if UserDefaults.standard.object(forKey: Self.caseSensitivityKey) as? Bool != standardValueBefore {
                UserDefaults.standard.set(standardValueBefore, forKey: Self.caseSensitivityKey)
            }
        }
        body()
    }
}
