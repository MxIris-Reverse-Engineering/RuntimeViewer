import AppKit
import DependenciesMacros
import FoundationToolbox
import OSLog
import RuntimeViewerArchitectures
import RuntimeViewerSettings
import RuntimeViewerSourceEditorBridge

/// Hands out the editors the content pane shows interfaces in, and builds the first one at launch.
///
/// The bridge lives in the `RuntimeViewerSourceEditorBridge` framework, which the app links and calls
/// directly, and which links the reconstructed `SourceEditor` frameworks in official builds. Any other
/// build — and the Intel half of a universal one, for which the frameworks have no slice — compiles
/// that framework without them: `isAvailable` is `false` there, and the content pane uses the
/// built-in `NSTextView`.
@MainActor
@Loggable(.private)
final class SourceEditorBridgeProvider {
    fileprivate static let shared = SourceEditorBridgeProvider()

    /// Built by `startPrewarming()` and handed to the first `makeBridge()` caller, so that building
    /// the editor view does not land on the click that opens the first runtime object.
    private var prewarmedBridge: SourceEditorBridging?

    /// The prewarm builds one bridge per process. A second one, built after the first was handed
    /// out, would only be thrown away.
    private var hasPrewarmed = false

    @Dependency(\.settings) private var settings

    /// Held for the lifetime of the process: the stored settings only arrive some time after
    /// launch, and a prewarmed bridge has to pick them up.
    private var settingsObserveToken: ObserveToken?

    private init() {}

    /// Whether this build shows interfaces in SourceEditor.
    var isAvailable: Bool {
        SourceEditorBridgeFactory.isAvailable
    }

    func makeBridge() -> SourceEditorBridging? {
        if let prewarmedBridge {
            self.prewarmedBridge = nil
            return prewarmedBridge
        }
        return makeNewBridge()
    }

    /// Builds one bridge at launch instead of on the click that first needs it, and keeps it in
    /// step with the stored settings until a document takes it.
    ///
    /// **What this is really buying is a Metal shader compile.** `installMinimap()` reaches
    /// `MinimapMetalLinesLayer.init`, whose `sharedPipelineState` is a `static let` — so the first
    /// minimap in the process compiles its render pipeline, and every later one gets it for free.
    /// A `sample` of a cold launch put that at **137 ms of the 185 ms** the first selection spent
    /// building the editor, and 130 of those 137 were the main thread *blocked* on
    /// `com.apple.MTLCompilerConnectionQueue` rather than doing work. The bridge is handed to the
    /// first document rather than discarded, which also saves that document the ~22 ms of view
    /// construction.
    ///
    /// **Observing is the point, not a nicety.** `SettingsLifecycleController.loadOnLaunch()` is
    /// `Task { await settings.load() }`, so a bridge configured right away gets the *default*
    /// display options, and the minimap is off by default. Applying the options again when the
    /// stored ones arrive installs the minimap then — still at launch, not on the first click. A
    /// user who leaves the minimap off pays nothing for it either way. `SettingsStore` is
    /// `@Observable` and `value` is one of its tracked properties, so replacing the model at the
    /// end of `load()` re-runs the observation; re-sending the same options is a no-op.
    ///
    /// Starts on the next turn of the main run loop: `SourceEditorView` is an `NSView`, so the
    /// construction has to happen on the main thread, but not inside
    /// `applicationDidFinishLaunching`.
    func startPrewarming() {
        guard isAvailable, settingsObserveToken == nil else { return }
        Task { @MainActor [weak self] in
            self?.observeSettingsForPrewarmedBridge()
        }
    }

    private func observeSettingsForPrewarmedBridge() {
        guard settingsObserveToken == nil else { return }
        settingsObserveToken = SwiftNavigation.observe { [weak self] in
            guard let self else { return }
            let editorSettings = settings.editor
            if !hasPrewarmed {
                hasPrewarmed = true
                prewarmedBridge = makeNewBridge()
                #log(.info, "SourceEditor prewarmed")
            }
            prewarmedBridge?.applyDisplayOptions(from: editorSettings)
        }
    }

    /// Reads one of the `.xccolortheme` files the framework ships in its own resources.
    /// `SourceEditorThemeConversion` uses one as the base to overwrite with the app's own
    /// theme, so the many keys a `ThemeProfile` has no opinion about stay valid.
    func builtInThemeDictionary(named themeName: String) -> NSDictionary? {
        SourceEditorBridgeFactory.builtInThemeDictionary(named: themeName)
    }

    private func makeNewBridge() -> SourceEditorBridging? {
        SourceEditorBridgeFactory.makeBridge()
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { SourceEditorBridgeProvider.shared })
    var sourceEditorBridgeProvider: SourceEditorBridgeProvider
}
