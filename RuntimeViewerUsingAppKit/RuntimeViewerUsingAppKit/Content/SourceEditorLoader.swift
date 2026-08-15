import AppKit
import Darwin
import DependenciesMacros
import FoundationToolbox
import OSLog
import RuntimeViewerArchitectures

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

    /// Deliberately not in dependency order. `loadFrameworks(from:)` sweeps to a fixed point
    /// instead of following a hand-maintained topological sort, so a future Xcode reshuffling
    /// the graph cannot silently break loading. The order below is alphabetical for reading.
    ///
    /// This is the display-path subset. `SymbolCache`, `SymbolCacheSupport` and
    /// `SymbolCacheIndexing` serve indexing and code completion, and loading without them is
    /// verified to work.
    private static let requiredFrameworkNames = [
        "SourceEditor",
        "SourceModel",
        "SourceModelSupport",
        "_CodeCompletionFoundation",
    ]

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

    private enum State {
        case notAttempted
        case ready(frameworksDirectory: URL, bridgeClass: SourceEditorBridging.Type)
        case unavailable(Unavailability)
    }

    private var state: State = .notAttempted

    private init() {}

    /// Opt-in switch. There is no Settings UI for it yet — the integration is experimental
    /// and, until the app's own `ThemeProfile` is translated into `.xccolortheme` form, it
    /// ignores the configured colors.
    ///
    ///     defaults write dev.mxiris.RuntimeViewer RuntimeViewerUsesExperimentalSourceEditor -bool YES
    ///
    /// Check this *before* `isAvailable`, so opting out also skips the `dlopen` work.
    var isEnabledByUser: Bool {
        UserDefaults.standard.bool(forKey: "RuntimeViewerUsesExperimentalSourceEditor")
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

    /// Reads one of the `.xccolortheme` files the framework ships in its own resources.
    /// RuntimeViewer's own themes are not yet translated into this format.
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
            state = resolve()
            if case .unavailable(let reason) = state {
                #log(.info, "SourceEditor unavailable, falling back to NSTextView: \(reason.description, privacy: .public)")
            }
        }
        return state
    }

    private func resolve() -> State {
        let candidates = candidateFrameworkDirectories()
        guard let frameworksDirectory = candidates.first(where: containsAllRequiredFrameworks) else {
            return .unavailable(.frameworksNotFound(searched: candidates.map(\.path)))
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

        #log(.info, "SourceEditor loaded from \(frameworksDirectory.path, privacy: .public)")
        return .ready(frameworksDirectory: frameworksDirectory, bridgeClass: bridgeClass)
    }

    /// Embedded copies win over Xcode's. That ordering is what lets a build that ships the
    /// frameworks and a build that borrows them from Xcode share one code path.
    private func candidateFrameworkDirectories() -> [URL] {
        var directories: [URL] = []

        if let embedded = Bundle.main.privateFrameworksURL {
            directories.append(embedded)
        }
        if let installedXcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
            directories.append(installedXcode.appending(path: "Contents/SharedFrameworks"))
        }
        directories.append(URL(fileURLWithPath: "/Applications/Xcode.app/Contents/SharedFrameworks"))

        var seenPaths = Set<String>()
        return directories.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
    }

    private func containsAllRequiredFrameworks(in directory: URL) -> Bool {
        Self.requiredFrameworkNames.allSatisfy { name in
            FileManager.default.fileExists(atPath: binaryURL(of: name, in: directory).path)
        }
    }

    private func binaryURL(of frameworkName: String, in directory: URL) -> URL {
        directory.appending(path: "\(frameworkName).framework/Versions/A/\(frameworkName)")
    }

    /// - Returns: the failure, or `nil` on success.
    private func loadFrameworks(from directory: URL) -> Unavailability? {
        var pending = Self.requiredFrameworkNames
        var lastFailedName = ""
        var lastFailureReason = ""

        while !pending.isEmpty {
            var stillPending: [String] = []
            for name in pending {
                let path = binaryURL(of: name, in: directory).path
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
