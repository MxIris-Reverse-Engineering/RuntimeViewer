#if os(macOS)

import Foundation
import Testing
@testable import RuntimeViewerHelperClient

/// Contract suite for `ApplicationBundleResourceLocator`, the locator that
/// answers from a RuntimeViewer application bundle.
///
/// The paths it produces are the ones `RuntimeInjectClient` and
/// `RuntimeHelperClient` used to compute from `Bundle.main` inline; a headless
/// process points the locator at an installed copy of the app instead.
@Suite("ApplicationBundleResourceLocator")
struct ApplicationBundleResourceLocatorTests {
    /// A directory shaped like the app bundle: the macOS payload in
    /// `Contents/Resources`, the Catalyst helper in `Contents/Applications`,
    /// and no simulator payload at all.
    private func makeApplicationBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationBundleResourceLocatorTests-\(UUID().uuidString)")
        let applicationBundleURL = root.appendingPathComponent("RuntimeViewer.app")
        let resourcesURL = applicationBundleURL.appendingPathComponent("Contents/Resources")
        let applicationsURL = applicationBundleURL.appendingPathComponent("Contents/Applications")
        try FileManager.default.createDirectory(
            at: resourcesURL.appendingPathComponent(PayloadPlatform.macOS.frameworkBundleName),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: applicationsURL.appendingPathComponent("RuntimeViewerCatalystHelper.app"),
            withIntermediateDirectories: true
        )
        return applicationBundleURL
    }

    @Test("A payload the bundle carries is found under Contents/Resources")
    func shippedPayloadIsFound() throws {
        let applicationBundleURL = try makeApplicationBundle()
        defer { try? FileManager.default.removeItem(at: applicationBundleURL.deletingLastPathComponent()) }
        let locator = ApplicationBundleResourceLocator(applicationBundleURL: applicationBundleURL)

        let payloadURL = try #require(locator.payloadFrameworkSourceURL(for: .macOS))

        #expect(payloadURL.standardizedFileURL.path.hasSuffix("/RuntimeViewer.app/Contents/Resources/RuntimeViewerServer.framework"))
    }

    @Test("A payload the bundle does not carry is reported as absent, not guessed")
    func missingPayloadIsNil() throws {
        let applicationBundleURL = try makeApplicationBundle()
        defer { try? FileManager.default.removeItem(at: applicationBundleURL.deletingLastPathComponent()) }
        let locator = ApplicationBundleResourceLocator(applicationBundleURL: applicationBundleURL)

        #expect(locator.payloadFrameworkSourceURL(for: .iOSSimulator) == nil)
    }

    @Test("The Catalyst helper is addressed under Contents/Applications")
    func catalystHelperPathIsInsideApplications() throws {
        let applicationBundleURL = try makeApplicationBundle()
        defer { try? FileManager.default.removeItem(at: applicationBundleURL.deletingLastPathComponent()) }
        let locator = ApplicationBundleResourceLocator(applicationBundleURL: applicationBundleURL)

        let helperURL = try #require(locator.catalystHelperApplicationURL)

        #expect(helperURL.standardizedFileURL.path.hasSuffix("/RuntimeViewer.app/Contents/Applications/RuntimeViewerCatalystHelper.app"))
        #expect(FileManager.default.fileExists(atPath: helperURL.path))
    }
}

#endif
