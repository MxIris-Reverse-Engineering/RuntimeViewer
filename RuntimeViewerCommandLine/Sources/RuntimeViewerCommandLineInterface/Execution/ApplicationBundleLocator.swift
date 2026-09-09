import CoreServices
import Darwin
import Foundation
#if os(macOS)
import RuntimeViewerHelperClient
#endif

/// Finds the RuntimeViewer application bundle a standalone host takes the
/// injection payload and the Catalyst helper from.
///
/// Tried in order: an explicit path (`host run --app-bundle`), the
/// `RUNTIME_VIEWER_APP_BUNDLE` environment variable, the `.app` enclosing the
/// running executable (a tool embedded in the app), and the installed app
/// Launch Services knows under the app's bundle identifiers. A candidate that
/// does not exist on disk is skipped. `nil` when all four miss; the local and
/// Bonjour sources work without it, `attach` and `catalyst` report
/// `applicationBundleNotFound` / `sourceUnavailable`.
public enum ApplicationBundleLocator {
    public static let environmentVariable = "RUNTIME_VIEWER_APP_BUNDLE"

    /// The app this build pairs with: a Debug tool looks for the Debug app,
    /// whose files and helper daemon it shares.
    #if DEBUG
    public static let defaultBundleIdentifiers = ["dev.JH.RuntimeViewer.arm64e", "dev.JH.RuntimeViewer"]
    #else
    public static let defaultBundleIdentifiers = ["com.JH.RuntimeViewer"]
    #endif

    public enum Step: String, Sendable, Hashable {
        case argument
        case environment
        case enclosingBundle
        case launchServices
    }

    public struct Resolution: Sendable, Hashable {
        public let bundleURL: URL
        public let step: Step

        public init(bundleURL: URL, step: Step) {
            self.bundleURL = bundleURL
            self.step = step
        }
    }

    public static func resolve(
        override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL,
        bundleIdentifiers: [String] = defaultBundleIdentifiers,
        installedApplications: (String) -> [URL] = launchServicesApplications(withBundleIdentifier:)
    ) -> Resolution? {
        if let override, !override.isEmpty, let bundleURL = existingBundle(atPath: override) {
            return Resolution(bundleURL: bundleURL, step: .argument)
        }
        if let fromEnvironment = environment[environmentVariable], !fromEnvironment.isEmpty, let bundleURL = existingBundle(atPath: fromEnvironment) {
            return Resolution(bundleURL: bundleURL, step: .environment)
        }
        if let executableURL, let bundleURL = enclosingApplicationBundle(of: executableURL) {
            return Resolution(bundleURL: bundleURL, step: .enclosingBundle)
        }
        for bundleIdentifier in bundleIdentifiers {
            for candidate in installedApplications(bundleIdentifier) {
                if let bundleURL = existingBundle(atPath: candidate.path) {
                    return Resolution(bundleURL: bundleURL, step: .launchServices)
                }
            }
        }
        return nil
    }

    /// The nearest `.app` directory above `executableURL`, or `nil` when the
    /// executable does not live inside one.
    static func enclosingApplicationBundle(of executableURL: URL) -> URL? {
        var url = executableURL.standardizedFileURL
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" {
                return existingBundle(atPath: url.path)
            }
        }
        return nil
    }

    private static func existingBundle(atPath path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    /// The installed applications with `bundleIdentifier`, most preferred first.
    ///
    /// Launch Services rather than `NSWorkspace.urlsForApplications(withBundleIdentifier:)`,
    /// so the tool does not link AppKit. `LSCopyApplicationURLsForBundleIdentifier`
    /// is deprecated in favour of that `NSWorkspace` method and nothing else in
    /// CoreServices answers the question, so it is reached through `dlsym`:
    /// same call, same registry, without the deprecation diagnostic on every
    /// build.
    public static func launchServicesApplications(withBundleIdentifier bundleIdentifier: String) -> [URL] {
        typealias CopyApplicationURLs = @convention(c) (CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFArray>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "LSCopyApplicationURLsForBundleIdentifier") else {
            return []
        }
        let copyApplicationURLs = unsafeBitCast(symbol, to: CopyApplicationURLs.self)
        guard let urls = copyApplicationURLs(bundleIdentifier as CFString, nil)?.takeRetainedValue() as? [URL] else {
            return []
        }
        return urls
    }

    #if os(macOS)
    /// The locator for a resolution: the bundle's own resources, or one that
    /// answers `nil` to everything when no bundle was found.
    public static func makeResourceLocator(for resolution: Resolution?) -> any RuntimeResourceLocating {
        if let resolution {
            return ApplicationBundleResourceLocator(applicationBundleURL: resolution.bundleURL)
        }
        return AbsentApplicationBundleResourceLocator()
    }
    #endif
}

#if os(macOS)
/// No application bundle: no payload, no Catalyst helper. The callers
/// (`RuntimeInjectClient`, `RuntimeHelperClient`) already throw for `nil`.
public struct AbsentApplicationBundleResourceLocator: RuntimeResourceLocating {
    public init() {}

    public func payloadFrameworkSourceURL(for platform: PayloadPlatform) -> URL? {
        nil
    }

    public var catalystHelperApplicationURL: URL? {
        nil
    }
}
#endif
