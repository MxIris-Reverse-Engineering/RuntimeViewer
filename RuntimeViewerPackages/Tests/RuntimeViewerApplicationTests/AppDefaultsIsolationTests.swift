import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// What `AppDefaults.isolated()` promises the suites that build one: a write
/// to one instance reaches no other, and none reaches the test process's
/// standard defaults.
///
/// The race these replace — a Find session rerunning its search because an
/// unrelated test changed the Generation Options — cannot be reproduced on
/// demand; these are its deterministic stand-ins. Each writes a value that
/// differs from what the instance holds, so a leftover from an earlier run
/// cannot hide a leak behind an equal value.
@Suite("AppDefaults isolation")
struct AppDefaultsIsolationTests {
    @Test("a Generation Options write stays in the instance it was made on")
    func optionsWriteStaysInItsInstance() {
        restoringStandardGenerationOptions {
            let writer = AppDefaults.isolated()
            let bystander = AppDefaults.isolated()
            let bystanderOptionsBefore = bystander.options

            writer.options = Self.toggled(writer.options)

            #expect(bystander.options == bystanderOptionsBefore, "another instance's write changed what this one reads")
        }
    }

    @Test("another instance's write is not observed")
    func otherInstanceWriteIsNotObserved() {
        restoringStandardGenerationOptions {
            let writer = AppDefaults.isolated()
            let bystander = AppDefaults.isolated()
            let writtenOptions = Self.toggled(writer.options)
            var observedWrites: [RuntimeObjectInterface.GenerationOptions] = []
            let disposeBag = DisposeBag()
            bystander.$options
                .filter { options in options == writtenOptions }
                .subscribeOnNext { options in observedWrites.append(options) }
                .disposed(by: disposeBag)

            // Key-value observation of a defaults key is delivered on the
            // writing thread, before the setter returns.
            writer.options = writtenOptions

            #expect(observedWrites.isEmpty, "this instance's options stream reported another instance's write")
            withExtendedLifetime(disposeBag) {}
        }
    }

    @Test("an isolated instance leaves the standard defaults alone")
    func isolatedInstanceLeavesStandardDefaultsAlone() {
        restoringStandardGenerationOptions {
            let standardOptionsBefore = UserDefaults.standard.data(forKey: Self.generationOptionsKey)
            let isolated = AppDefaults.isolated()

            isolated.options = Self.toggled(isolated.options)

            #expect(
                UserDefaults.standard.data(forKey: Self.generationOptionsKey) == standardOptionsBefore,
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
        appDefaults.options = toggled(appDefaults.options)
        #expect(appDefaults.userDefaultsNamespace.isolatedKeys?.isEmpty == false, "the write never reached the isolated suite")
        return appDefaults.userDefaultsNamespace
    }

    /// The key the app keeps its Generation Options under in the standard
    /// defaults.
    private static let generationOptionsKey = "generationOptions"

    /// Different from whatever `options` holds — including whatever an
    /// earlier run left behind — so a leak cannot hide behind an equal value.
    private static func toggled(
        _ options: RuntimeObjectInterface.GenerationOptions
    ) -> RuntimeObjectInterface.GenerationOptions {
        var toggledOptions = options
        toggledOptions.objcHeaderOptions.stripSynthesizedIvars.toggle()
        return toggledOptions
    }

    /// Puts the test process's standard Generation Options back if `body`
    /// changed them, which only a broken isolation does. Written only on a
    /// difference, so a passing run never touches the standard defaults; a
    /// failing one does not leave its write behind for the next run to read.
    private func restoringStandardGenerationOptions(_ body: () -> Void) {
        let standardOptionsBefore = UserDefaults.standard.data(forKey: Self.generationOptionsKey)
        defer {
            if UserDefaults.standard.data(forKey: Self.generationOptionsKey) != standardOptionsBefore {
                UserDefaults.standard.set(standardOptionsBefore, forKey: Self.generationOptionsKey)
            }
        }
        body()
    }
}
