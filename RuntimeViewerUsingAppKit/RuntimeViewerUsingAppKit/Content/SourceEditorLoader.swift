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

    /// Set for as long as `prewarm()` has work in flight, so a second call does not start a
    /// second load. A synchronous `resolvedState()` arriving meanwhile is *not* blocked by it:
    /// `dlopen` and `Bundle.load` are both idempotent and thread-safe, so the worst case is
    /// that the caller waits on the same work the task is already doing.
    private var isPrewarming = false

    private init() {}

    /// Whether the user asked for it — see Settings › Editor. Check this *before*
    /// `isAvailable`, so leaving it off also skips the `dlopen` work.
    var isEnabledByUser: Bool {
        @Dependency(\.settings) var settings
        return settings.editor.usesSourceEditor
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
        guard case .ready(_, let bridgeClass) = resolvedState() else { return nil }
        return bridgeClass.init()
    }

    /// Loads the frameworks off the main thread so the first document does not pay for them.
    ///
    /// Measured on a warm file cache: the four `dlopen`s cost ~60 ms and the bridge bundle ~1 ms,
    /// against ~9 ms to build the editor view and ~9 ms per `setSource` afterwards. That whole
    /// ~60 ms lands on whichever click first opens a runtime object, which is what reads as the
    /// first selection being slow while every later one is not.
    ///
    /// All of it moves off the main thread cleanly — the loading is plain dyld and `NSBundle`
    /// work — leaving only the view construction, which is `NSView` and has to stay here.
    ///
    /// Does nothing when the editor is switched off in Settings, so a user who never turns it on
    /// never loads Xcode's frameworks.
    func prewarm() {
        guard isEnabledByUser, !isPrewarming, case .notAttempted = state else { return }
        isPrewarming = true

        Task.detached(priority: .utility) {
            let resolved = Self.resolve()
            await MainActor.run {
                self.isPrewarming = false
                // A document opened while this ran would have resolved the state itself; that
                // answer is the same one, and overwriting it would discard a `ready` for a
                // second identical `ready`.
                guard case .notAttempted = self.state else { return }
                self.state = resolved
                self.logResolution(of: resolved)
            }
        }
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
            logResolution(of: state)
        }
        return state
    }

    private func logResolution(of state: State) {
        switch state {
        case .notAttempted:
            break
        case .ready(let frameworksDirectory, _):
            #log(.info, "SourceEditor loaded from \(frameworksDirectory.path, privacy: .public)")
        case .unavailable(let reason):
            #log(.info, "SourceEditor unavailable, falling back to NSTextView: \(reason.description, privacy: .public)")
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
