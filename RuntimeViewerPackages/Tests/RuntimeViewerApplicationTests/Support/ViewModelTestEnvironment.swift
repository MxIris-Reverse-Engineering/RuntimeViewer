import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// Everything a ViewModel resolves through `@Dependency`, pointed at
/// test-owned instances, plus a `DocumentState` bound to the given engine.
///
/// Build ViewModels inside `make` so their `@Dependency` wrappers capture these
/// overrides. A ViewModel built outside resolves the production singletons,
/// and for `appDefaults` that means the user's real bookmark files.
///
/// `settings` is `SettingsAccess.preview`, an in-memory store: the live one is
/// backed by the developer's own `RuntimeViewer-Debug/settings.json`, and a
/// write from a test would auto-save over it. Keep Interfaces Searchable and
/// Keep Cross References Ready start off there, unlike in the app: on, every
/// document a test starts on an engine would set the engine's process
/// building the corpora of its indexed images — Foundation's takes seconds —
/// and preparing their cross references in the background, holding the
/// activity and the Report rows other tests count, and competing with the
/// indexing they time. The tests about them turn them on.
@MainActor
struct ViewModelTestEnvironment {
    let appDefaults: AppDefaults
    let settings: SettingsAccess
    let resolvedThemeStream: ResolvedThemeStream
    let documentState: DocumentState

    init(runtimeEngine: RuntimeEngine? = nil) {
        let appDefaults = AppDefaults.isolated()
        let settings = SettingsAccess.preview
        settings.search.isCorpusEnabled = false
        settings.search.isCrossReferencePreparationEnabled = false
        self.appDefaults = appDefaults
        self.settings = settings
        self.resolvedThemeStream = withDependencies {
            $0.settings = settings
        } operation: {
            ResolvedThemeStream()
        }
        self.documentState = DocumentState()
        if let runtimeEngine {
            documentState.selectionRouter.trigger(.switchEngine(runtimeEngine))
        }
    }

    func make<Result>(_ build: () throws -> Result) rethrows -> Result {
        try withDependencies(
            {
                $0.appDefaults = appDefaults
                $0.settings = settings
                $0.resolvedThemeStream = resolvedThemeStream
            },
            operation: build
        )
    }

    /// Where the document's background work comes from: the test's own
    /// registry, which every document a test opens shares.
    var backgroundWorkRegistry: RuntimeEngineBackgroundWorkRegistry {
        @Dependency(\.runtimeEngineBackgroundWorkRegistry) var backgroundWorkRegistry
        return backgroundWorkRegistry
    }

    /// Starts the document's background work as `Document.makeWindowControllers`
    /// does, inside the environment's dependencies so the coordinators it
    /// brings into being read the test's settings. What is bound before it
    /// finds the work once it runs, as everything follows the session it puts
    /// in place.
    func startBackgroundWork() {
        make { documentState.startBackgroundWork() }
    }
}

extension AppDefaults {
    /// A store in a fresh temporary directory and a user defaults namespace
    /// of its own, so instances built by tests running in parallel never see
    /// each other's files or options, and nothing from an earlier run leaks
    /// in.
    static func isolated() -> AppDefaults {
        AppDefaults(
            storageDirectoryURL: makeTemporaryStorageDirectoryURL(label: "isolated"),
            userDefaultsNamespace: .makeIsolated()
        )
    }
}
