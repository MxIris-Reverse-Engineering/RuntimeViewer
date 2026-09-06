#if os(macOS)

import Foundation
import Dependencies
import DependenciesMacros

/// Where the pieces RuntimeViewer ships alongside itself are found: the
/// injectable payload bundles and the Mac Catalyst helper application.
///
/// The app answers from its own bundle. A process that is not the app — a
/// command-line tool, a test — supplies its own answer through
/// `\.runtimeResourceLocator`, instead of every call site reaching for
/// `Bundle.main` and finding a bundle that carries none of this.
public protocol RuntimeResourceLocating: Sendable {
    /// The payload bundle shipped for `platform`, or `nil` when this build
    /// carries none.
    func payloadFrameworkSourceURL(for platform: PayloadPlatform) -> URL?

    /// `RuntimeViewerCatalystHelper.app`, or `nil` when there is no
    /// application bundle to look inside.
    var catalystHelperApplicationURL: URL? { get }
}

/// Resolves against a RuntimeViewer application bundle: payloads under
/// `Contents/Resources`, the Catalyst helper under `Contents/Applications`.
public struct ApplicationBundleResourceLocator: RuntimeResourceLocating {
    public static let catalystHelperApplicationName = "RuntimeViewerCatalystHelper"

    public let applicationBundleURL: URL

    public init(applicationBundleURL: URL) {
        self.applicationBundleURL = applicationBundleURL
    }

    public func payloadFrameworkSourceURL(for platform: PayloadPlatform) -> URL? {
        // Through `Bundle` rather than path arithmetic, so the lookup keeps
        // matching what `Bundle.main.url(forResource:withExtension:)` did
        // when the app was the only caller.
        Bundle(url: applicationBundleURL)?.url(forResource: platform.frameworkBundleBaseName, withExtension: "framework")
    }

    public var catalystHelperApplicationURL: URL? {
        applicationBundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Applications")
            .appendingPathComponent("\(Self.catalystHelperApplicationName).app")
    }
}

// MARK: - Dependencies

extension DependencyValues {
    /// Defaults to the running process's own bundle, which is the app's
    /// behaviour from before this seam existed.
    @DependencyEntry(liveValue: ApplicationBundleResourceLocator(applicationBundleURL: Bundle.main.bundleURL))
    public var runtimeResourceLocator: any RuntimeResourceLocating
}

#endif
