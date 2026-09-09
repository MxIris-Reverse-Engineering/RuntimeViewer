import Foundation
import Testing
@testable import RuntimeViewerCommandLineInterface

/// The four-step search for RuntimeViewer.app, each step overriding the next.
@Suite("Application bundle locator")
struct ApplicationBundleLocatorTests {
    private struct Fixture {
        let root: URL
        let argumentBundle: URL
        let environmentBundle: URL
        let enclosingBundle: URL
        let executableInsideBundle: URL
        let installedBundle: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ApplicationBundleLocatorTests-\(UUID().uuidString)", isDirectory: true)
            argumentBundle = root.appendingPathComponent("Argument/RuntimeViewer.app", isDirectory: true)
            environmentBundle = root.appendingPathComponent("Environment/RuntimeViewer.app", isDirectory: true)
            enclosingBundle = root.appendingPathComponent("Enclosing/RuntimeViewer.app", isDirectory: true)
            executableInsideBundle = enclosingBundle.appendingPathComponent("Contents/Helpers/runtime-viewer-cli")
            installedBundle = root.appendingPathComponent("Applications/RuntimeViewer.app", isDirectory: true)
            for bundle in [argumentBundle, environmentBundle, enclosingBundle, installedBundle] {
                try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            }
            try FileManager.default.createDirectory(at: executableInsideBundle.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: executableInsideBundle)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        var environment: [String: String] {
            [ApplicationBundleLocator.environmentVariable: environmentBundle.path]
        }

        func installed(_ bundleIdentifier: String) -> [URL] {
            bundleIdentifier == "dev.example.RuntimeViewer" ? [installedBundle] : []
        }
    }

    @Test("An explicit path wins over everything")
    func argumentWins() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let resolution = ApplicationBundleLocator.resolve(
            override: fixture.argumentBundle.path,
            environment: fixture.environment,
            executableURL: fixture.executableInsideBundle,
            bundleIdentifiers: ["dev.example.RuntimeViewer"],
            installedApplications: fixture.installed
        )

        #expect(resolution?.step == .argument)
        #expect(resolution?.bundleURL.standardizedFileURL == fixture.argumentBundle.standardizedFileURL)
    }

    @Test("The environment variable is next")
    func environmentIsNext() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let resolution = ApplicationBundleLocator.resolve(
            override: nil,
            environment: fixture.environment,
            executableURL: fixture.executableInsideBundle,
            bundleIdentifiers: ["dev.example.RuntimeViewer"],
            installedApplications: fixture.installed
        )

        #expect(resolution?.step == .environment)
        #expect(resolution?.bundleURL.standardizedFileURL == fixture.environmentBundle.standardizedFileURL)
    }

    @Test("A tool that lives inside an app bundle uses that bundle")
    func enclosingBundleIsNext() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let resolution = ApplicationBundleLocator.resolve(
            override: nil,
            environment: [:],
            executableURL: fixture.executableInsideBundle,
            bundleIdentifiers: ["dev.example.RuntimeViewer"],
            installedApplications: fixture.installed
        )

        #expect(resolution?.step == .enclosingBundle)
        #expect(resolution?.bundleURL.standardizedFileURL == fixture.enclosingBundle.standardizedFileURL)
    }

    @Test("Otherwise the installed app is looked up by bundle identifier, first identifier first")
    func launchServicesIsLast() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let resolution = ApplicationBundleLocator.resolve(
            override: nil,
            environment: [:],
            executableURL: URL(fileURLWithPath: "/usr/local/bin/runtime-viewer-cli"),
            bundleIdentifiers: ["dev.example.Missing", "dev.example.RuntimeViewer"],
            installedApplications: fixture.installed
        )

        #expect(resolution?.step == .launchServices)
        #expect(resolution?.bundleURL.standardizedFileURL == fixture.installedBundle.standardizedFileURL)
    }

    @Test("A path that does not exist is skipped, not returned")
    func missingCandidatesAreSkipped() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let resolution = ApplicationBundleLocator.resolve(
            override: fixture.root.appendingPathComponent("Nowhere.app").path,
            environment: [ApplicationBundleLocator.environmentVariable: fixture.root.appendingPathComponent("AlsoNowhere.app").path],
            executableURL: URL(fileURLWithPath: "/usr/local/bin/runtime-viewer-cli"),
            bundleIdentifiers: ["dev.example.RuntimeViewer"],
            installedApplications: { _ in [fixture.root.appendingPathComponent("Gone.app")] }
        )

        #expect(resolution == nil)
    }

    @Test("Without a bundle the resource locator answers nil to everything")
    func absentLocator() {
        let locator = ApplicationBundleLocator.makeResourceLocator(for: nil)

        #expect(locator.catalystHelperApplicationURL == nil)
        #expect(locator.payloadFrameworkSourceURL(for: .macOS) == nil)
        #expect(locator.payloadFrameworkSourceURL(for: .iOSSimulator) == nil)
    }

    @Test("With a bundle the resource locator points inside it")
    func bundleLocator() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let locator = ApplicationBundleLocator.makeResourceLocator(for: .init(bundleURL: fixture.installedBundle, step: .launchServices))

        #expect(locator.catalystHelperApplicationURL?.path.hasSuffix("/RuntimeViewer.app/Contents/Applications/RuntimeViewerCatalystHelper.app") == true)
    }
}
