import AppKit
import Darwin
import DependenciesMacros
import FoundationToolbox
import OSLog
import RuntimeViewerArchitectures
import RuntimeViewerSettings

/// Brings up Xcode's private `SourceEditor` framework at runtime and hands back a bridge
/// object that can drive it.
///
/// The app links none of this. It cannot: a link-time dependency on frameworks that live
/// inside Xcode would abort in dyld before `main` on any machine without Xcode installed.
/// So the frameworks are `dlopen`ed by absolute path, and the only code that references
/// their symbols lives in a loadable bundle brought up afterwards — see `SourceEditorBridging`.
///
/// **Every failure here is recoverable.** Nothing in this file may trap: the caller falls
/// back to the built-in `NSTextView` content view, which is the shipping behaviour whenever
/// the editor cannot be loaded.
@MainActor
@Loggable(.private)
final class SourceEditorLoader {
    fileprivate static let shared = SourceEditorLoader()

    private static let bridgeBundleName = "RuntimeViewerSourceEditorBridge.bundle"

    enum Unavailability: Error, CustomStringConvertible {
        /// No directory held all of the required frameworks.
        case frameworksNotFound(searched: [String])
        case frameworkLoadFailed(name: String, reason: String)
        case bridgeBundleMissing
        case bridgeBundleLoadFailed(reason: String)
        case bridgePrincipalClassUnusable

        var description: String {
            switch self {
            case .frameworksNotFound(let searched):
                "Xcode's SourceEditor frameworks were not found. Searched: \(searched.joined(separator: ", "))"
            case .frameworkLoadFailed(let name, let reason):
                "Failed to load \(name): \(reason)"
            case .bridgeBundleMissing:
                "\(SourceEditorLoader.bridgeBundleName) is missing from the app's PlugIns directory"
            case .bridgeBundleLoadFailed(let reason):
                "Failed to load \(SourceEditorLoader.bridgeBundleName): \(reason)"
            case .bridgePrincipalClassUnusable:
                "\(SourceEditorLoader.bridgeBundleName) has no principal class conforming to SourceEditorBridging"
            }
        }
    }

    /// `@unchecked` for the bridge class: an existential metatype is not `Sendable`, and this
    /// value crosses back from the prewarm task. Safe because the only mutable state it reaches
    /// — `state` below — is written on the main actor, and a loaded class is immutable.
    private enum State: @unchecked Sendable {
        case notAttempted
        case ready(frameworksDirectory: URL, bridgeClass: SourceEditorBridging.Type)
        case unavailable(Unavailability)
    }

    private var state: State = .notAttempted

    /// Built by `prewarm()` and handed to the first `makeBridge()` caller, so that building the
    /// editor view does not land on the click that opens the first runtime object.
    private var prewarmedBridge: SourceEditorBridging?

    /// Set for as long as `prewarm()` has work in flight, so a second call does not start a
    /// second load. A synchronous `resolvedState()` arriving meanwhile is *not* blocked by it:
    /// `dlopen` and `Bundle.load` are both idempotent and thread-safe, so the worst case is
    /// that the caller waits on the same work the task is already doing.
    private var isPrewarming = false

    @Dependency(\.settings) private var settings

    /// Held for the lifetime of the process: the editor can be switched on at any point, and the
    /// stored value only arrives some time after launch.
    private var settingsObserveToken: ObserveToken?

    private init() {}

    /// Whether the user asked for it — see Settings › Editor. Check this *before*
    /// `isAvailable`, so leaving it off also skips the `dlopen` work.
    var isEnabledByUser: Bool {
        settings.editor.usesSourceEditor
    }

    /// Whether a bridge can be created. Resolves on first call and is cached — including the
    /// failure, since a failed `dlopen` will not start succeeding within one launch.
    var isAvailable: Bool {
        if case .ready = resolvedState() { return true }
        return false
    }

    var unavailability: Unavailability? {
        if case .unavailable(let reason) = resolvedState() { return reason }
        return nil
    }

    func makeBridge() -> SourceEditorBridging? {
        if let prewarmedBridge {
            self.prewarmedBridge = nil
            return prewarmedBridge
        }
        guard case .ready(_, let bridgeClass) = resolvedState() else { return nil }
        return bridgeClass.init()
    }

    /// Loads the frameworks off the main thread so the first document does not pay for them.
    ///
    /// Measured on a warm file cache: the four `dlopen`s cost ~60 ms and the bridge bundle ~1 ms,
    /// against ~9 ms to build the editor view and ~9 ms per `setSource` afterwards. That whole
    /// ~60 ms would otherwise land on whichever click first opens a runtime object.
    ///
    /// All of it moves off the main thread cleanly — the loading is plain dyld and `NSBundle`
    /// work — leaving only the view construction, which is `NSView` and has to stay here.
    ///
    /// **Loading was never the larger half.** A `sample` taken once this was working showed no
    /// `dlopen` on the first selection at all, and 137 ms of Metal shader compilation instead —
    /// see `prewarmBridge()`, which the completion below now runs for exactly that reason.
    ///
    /// Prewarms as soon as the editor is switched on: at launch once the stored settings have
    /// been read, or the moment the user turns it on in Settings.
    ///
    /// **Observing is the point, not a nicety.** `SettingsLifecycleController.loadOnLaunch()` is
    /// `Task { await settings.load() }`, so anything that reads a setting synchronously after it
    /// — as this used to, from `applicationDidFinishLaunching` — reads the *default*, and the
    /// editor's master switch defaults to off. The prewarm then declined to run at all. That is
    /// what a Time Profiler trace of the first selection actually showed: the whole 81 ms
    /// `dlopen` on the main thread with no worker thread doing the same work, which is the
    /// signature of a prewarm that never started rather than one that started late.
    ///
    /// `SettingsStore` is `@Observable` and `value` is one of its tracked properties, so
    /// replacing the model at the end of `load()` re-runs this.
    func startPrewarmingWhenEnabled() {
        guard settingsObserveToken == nil else { return }
        settingsObserveToken = SwiftNavigation.observe { [weak self] in
            guard let self, settings.editor.usesSourceEditor else { return }
            prewarm()
        }
    }

    /// Does nothing when the editor is switched off in Settings, so a user who never turns it on
    /// never loads Xcode's frameworks.
    ///
    /// Runs at `userInitiated` because it is racing the user's first click, and launch — the
    /// busiest stretch the app has — is exactly what it has to get in front of. Losing that race
    /// is not a correctness problem (the click does the work itself, as it did before) but it
    /// makes the prewarm pointless.
    func prewarm() {
        guard isEnabledByUser, !isPrewarming, case .notAttempted = state else { return }
        isPrewarming = true

        DispatchQueue.global(qos: .userInitiated).async {
            let resolved = Self.resolve()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isPrewarming = false
                    // A document opened while this ran would have resolved the state itself; that
                    // answer is the same one, and overwriting it would discard a `ready` for a
                    // second identical `ready`.
                    guard case .notAttempted = self.state else { return }
                    self.state = resolved
                    self.logResolution(of: resolved, wasPrewarmed: true)
                    self.prewarmBridge()
                }
            }
        }
    }

    /// Builds one bridge now instead of on the click that first needs it, and configures it the
    /// way `ContentSourceEditorViewController` would.
    ///
    /// **What this is really buying is a Metal shader compile.** `installMinimap()` reaches
    /// `MinimapMetalLinesLayer.init`, whose `sharedPipelineState` is a `static let` — so the first
    /// minimap in the process compiles its render pipeline, and every later one gets it for free.
    /// A `sample` of a cold launch put that at **137 ms of the 185 ms** the first selection spent
    /// building the editor, and 130 of those 137 were the main thread *blocked* on
    /// `com.apple.MTLCompilerConnectionQueue` rather than doing work. That is the whole reason the
    /// first object opened felt slow while every later one did not: a one-time, process-wide cost
    /// that no amount of caching further up could hide. Loading the frameworks — what this
    /// prewarm covered before — never touched it.
    ///
    /// Applying the current display options is not incidental: without `showsMinimap` on, none of
    /// the above happens. It also means a user who leaves the minimap off pays nothing here, and
    /// nothing at the click either.
    ///
    /// **Has to be on the main thread**, since `SourceEditorView` is an `NSView`, so this is a
    /// main-thread stall of roughly the same size — moved off the user's click and onto launch,
    /// where the main thread is otherwise ~80% idle while the object list loads in the background.
    ///
    /// The bridge is handed to the first document rather than discarded, which also saves that
    /// document the ~22 ms of view construction. Everything the view controller does on top —
    /// theme, content inset, navigation delegate, `setSource` — is applied there as usual, and
    /// re-sending the same display options is a no-op.
    private func prewarmBridge() {
        guard isEnabledByUser, prewarmedBridge == nil, case .ready(_, let bridgeClass) = state else { return }
        let bridge = bridgeClass.init()
        bridge.applyDisplayOptions(from: settings.editor)
        prewarmedBridge = bridge
    }

    /// Reads one of the `.xccolortheme` files the framework ships in its own resources.
    /// `SourceEditorThemeConversion` uses one as the base to overwrite with the app's own
    /// theme, so the many keys a `ThemeProfile` has no opinion about stay valid.
    func builtInThemeDictionary(named themeName: String) -> NSDictionary? {
        guard case .ready(let frameworksDirectory, _) = resolvedState() else { return nil }
        let themeURL = frameworksDirectory
            .appending(path: "SourceEditor.framework/Versions/A/Resources")
            .appending(path: "\(themeName).xccolortheme")
        return NSDictionary(contentsOf: themeURL)
    }

    // MARK: - Resolution

    private func resolvedState() -> State {
        if case .notAttempted = state {
            state = Self.resolve()
            logResolution(of: state, wasPrewarmed: false)
        }
        return state
    }

    /// - Parameter wasPrewarmed: whether this resolution came from `prewarm()`. Logged because it
    ///   is the difference between the first selection being instant and it paying ~80 ms, and
    ///   nothing else in the app's behaviour reveals which one happened.
    private func logResolution(of state: State, wasPrewarmed: Bool) {
        let origin = wasPrewarmed ? "prewarmed" : "on demand"
        switch state {
        case .notAttempted:
            break
        case .ready(let frameworksDirectory, _):
            #log(.info, "SourceEditor loaded \(origin, privacy: .public) from \(frameworksDirectory.path, privacy: .public)")
        case .unavailable(let reason):
            #log(.info, "SourceEditor unavailable (\(origin, privacy: .public)), falling back to NSTextView: \(reason.description, privacy: .public)")
        }
    }

    /// `nonisolated` so `prewarm()` can run it off the main thread. Nothing in it touches the
    /// loader's own state — the result is handed back and stored by the caller — and its two
    /// halves, `dlopen` and `Bundle`, are both usable from any thread.
    private nonisolated static func resolve() -> State {
        guard let frameworksDirectory = XcodeSourceEditorLocator.frameworksDirectory() else {
            return .unavailable(.frameworksNotFound(searched: XcodeSourceEditorLocator.candidateDirectories().map(\.path)))
        }

        if let failure = loadFrameworks(from: frameworksDirectory) {
            return .unavailable(failure)
        }

        guard let bundleURL = Bundle.main.builtInPlugInsURL?.appending(path: Self.bridgeBundleName),
              let bundle = Bundle(url: bundleURL)
        else {
            return .unavailable(.bridgeBundleMissing)
        }

        do {
            try bundle.loadAndReturnError()
        } catch {
            return .unavailable(.bridgeBundleLoadFailed(reason: error.localizedDescription))
        }

        guard let bridgeClass = bundle.principalClass as? SourceEditorBridging.Type else {
            return .unavailable(.bridgePrincipalClassUnusable)
        }

        return .ready(frameworksDirectory: frameworksDirectory, bridgeClass: bridgeClass)
    }

    /// - Returns: the failure, or `nil` on success.
    private nonisolated static func loadFrameworks(from directory: URL) -> Unavailability? {
        var pending = XcodeSourceEditorLocator.requiredFrameworkNames
        var lastFailedName = ""
        var lastFailureReason = ""

        while !pending.isEmpty {
            var stillPending: [String] = []
            for name in pending {
                let path = XcodeSourceEditorLocator.binaryURL(of: name, in: directory).path
                if dlopen(path, RTLD_LAZY | RTLD_GLOBAL) == nil {
                    lastFailedName = name
                    lastFailureReason = dlerror().map { String(cString: $0) } ?? "unknown dlopen failure"
                    stillPending.append(name)
                }
            }
            // Their install names are all `@rpath/…`, and they depend on each other. One
            // whose own dependencies are not loaded yet fails this pass and succeeds a later
            // one — so only give up when an entire pass makes no progress.
            if stillPending.count == pending.count {
                return .frameworkLoadFailed(name: lastFailedName, reason: lastFailureReason)
            }
            pending = stillPending
        }
        return nil
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { SourceEditorLoader.shared })
    var sourceEditorLoader: SourceEditorLoader
}
