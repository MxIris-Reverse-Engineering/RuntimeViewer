#if os(macOS)

import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// A window's Load Frameworks (proposal `isolated-framework-loading`): the
/// frameworks loaded in order, a refusal stopping the rest with its diagnosis,
/// the remedies, and the instance going away. The loads and diagnoses are
/// scripted (`FrameworkLoader.ImageLoading`); the frameworks are bundles in a
/// temporary directory, so their executables resolve as the open panel's do.
@Suite("Framework loader")
@MainActor
struct FrameworkLoaderTests {
    // MARK: - Fixtures

    /// Shallow framework bundles named `names`, in a directory of the test's own.
    private static func makeFrameworks(_ names: [String]) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameworkLoaderTests-\(UUID().uuidString)", isDirectory: true)
        return try names.map { name in
            let bundleURL = directory.appendingPathComponent("\(name).framework", isDirectory: true)
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            let infoPlist: [String: Any] = ["CFBundleExecutable": name, "CFBundlePackageType": "FMWK", "CFBundleIdentifier": "test.\(name)"]
            try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
                .write(to: bundleURL.appendingPathComponent("Info.plist"))
            FileManager.default.createFile(atPath: bundleURL.appendingPathComponent(name).path, contents: Data())
            return bundleURL
        }
    }

    private static func imagePath(of frameworkURL: URL) throws -> String {
        try FrameworkLoader.executablePath(ofFrameworkAt: frameworkURL, resolvingLinks: true)
    }

    private static func frameworkInstanceEngine() -> RuntimeEngine {
        RuntimeEngine(
            source: .frameworkInstance(name: "Foo.framework (Isolated)", frameworkURL: URL(fileURLWithPath: "/A/Foo.framework"), identifier: .init(rawValue: UUID().uuidString)),
            engineID: "FrameworkLoaderTests.\(UUID().uuidString)"
        )
    }

    private static func refusal(of imagePath: String, remedy: RuntimeImageLoadDiagnosis.Remedy? = nil) -> RuntimeImageLoadError {
        let message = "dlopen(\(imagePath), 0x0001): Library not loaded: @rpath/Bar.framework/Versions/A/Bar\n  Referenced from: <6E1F3A2C-0B7D-3F4E-9A51-2C8D7E4B1F09> \(imagePath)\n  Reason: tried: '/X/Bar' (no such file)"
        var diagnosis = RuntimeImageLoadDiagnosis(dyldMessage: message, imagePath: imagePath)
        diagnosis.isFromMessageOnly = false
        diagnosis.remedy = remedy
        return RuntimeImageLoadError(dyldMessage: message, diagnosis: diagnosis)
    }

    /// Scripted loads and diagnoses, recording what was asked.
    @MainActor
    private final class Script {
        var refusals: [String: any Error] = [:]
        var loadedImagePaths: [String] = []
        var diagnoseRequests: [(hostApplicationPath: String?, searchPaths: [String])] = []
        var retracedRemedy: RuntimeImageLoadDiagnosis.Remedy?

        var imageLoading: FrameworkLoader.ImageLoading {
            FrameworkLoader.ImageLoading(
                loadImage: { [self] _, imagePath in
                    loadedImagePaths.append(imagePath)
                    if let refusal = refusals[imagePath] { throw refusal }
                },
                diagnoseImageLoad: { [self] _, diagnosis, hostApplicationPath, searchPaths in
                    diagnoseRequests.append((hostApplicationPath, searchPaths))
                    var retraced = diagnosis
                    retraced.remedy = retracedRemedy
                    return retraced
                },
                waitUntilReady: { _ in }
            )
        }
    }

    /// A failure that crossed a connection from a process of an earlier
    /// version: its text, nothing else.
    private struct TextOnlyFailure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private struct Fixture {
        let environment: ViewModelTestEnvironment
        let loader: FrameworkLoader
        let script: Script
    }

    private static func makeFixture(on engine: RuntimeEngine) -> Fixture {
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let script = Script()
        let loader = environment.documentState.frameworkLoader
        loader.imageLoading = script.imageLoading
        return Fixture(environment: environment, loader: loader, script: script)
    }

    // MARK: - Loading

    @Test("frameworks load in order and the loader ends idle")
    func loaderLoadsFrameworksInOrder() async throws {
        let frameworks = try Self.makeFrameworks(["Foo", "Bar"])
        let fixture = Self.makeFixture(on: Self.frameworkInstanceEngine())

        await fixture.loader.load(frameworksAt: frameworks)

        #expect(fixture.script.loadedImagePaths == (try frameworks.map(Self.imagePath(of:))))
        #expect(fixture.loader.state == .idle)
    }

    @Test("every load is recorded in the Report's Manual Loading")
    func loaderRecordsManualLoads() async throws {
        let frameworks = try Self.makeFrameworks(["Foo"])
        let fixture = Self.makeFixture(on: Self.frameworkInstanceEngine())
        fixture.environment.startBackgroundWork()
        let imagePath = try Self.imagePath(of: frameworks[0])

        await fixture.loader.load(frameworksAt: frameworks)

        let coordinator = try #require(fixture.environment.documentState.runtimeEngineSession.backgroundWork(forImageAt: imagePath)?.manualImageLoadCoordinator)
        #expect(coordinator.finishedLoads.map(\.imagePath) == [imagePath])
    }

    @Test("a refusal stops the load there, keeping the frameworks after it, with the diagnosis")
    func loaderStopsAtTheFirstRefusalAndKeepsTheRest() async throws {
        let frameworks = try Self.makeFrameworks(["Foo", "Bar"])
        let fixture = Self.makeFixture(on: Self.frameworkInstanceEngine())
        let fooPath = try Self.imagePath(of: frameworks[0])
        fixture.script.refusals[fooPath] = Self.refusal(of: fooPath)

        await fixture.loader.load(frameworksAt: frameworks)

        guard case .failed(let failure) = fixture.loader.state else {
            Issue.record("not failed: \(fixture.loader.state)")
            return
        }
        #expect(failure.frameworkURL == frameworks[0])
        #expect(failure.remainingFrameworkURLs == [frameworks[1]])
        #expect(failure.offersRemedies)
        #expect(failure.diagnosis.failure.kind == .imageNotFound)
        #expect(fixture.script.loadedImagePaths == [fooPath])
    }

    @Test("retrying after a fix loads the refused framework and then the rest")
    func retryAfterFixContinuesWithTheRemainingFrameworks() async throws {
        let frameworks = try Self.makeFrameworks(["Foo", "Bar"])
        let fixture = Self.makeFixture(on: Self.frameworkInstanceEngine())
        let fooPath = try Self.imagePath(of: frameworks[0])
        fixture.script.refusals[fooPath] = Self.refusal(of: fooPath)
        await fixture.loader.load(frameworksAt: frameworks)
        fixture.script.refusals = [:]

        await fixture.loader.retry()

        #expect(fixture.script.loadedImagePaths == [fooPath, fooPath, try Self.imagePath(of: frameworks[1])])
        #expect(fixture.loader.state == .idle)
    }

    // MARK: - Remedies

    @Test("the remedy loads its images first, dependencies before dependents, then the refused framework, and keeps the host app")
    func applyRemedyLoadsDependenciesFirstThenRetries() async throws {
        let frameworks = try Self.makeFrameworks(["Foo"])
        let fixture = Self.makeFixture(on: Self.frameworkInstanceEngine())
        let fooPath = try Self.imagePath(of: frameworks[0])
        let remedy = RuntimeImageLoadDiagnosis.Remedy(hostApplicationPath: "/Apps/Example.app", searchPaths: [], imagePathsToLoadFirst: ["/Apps/Example.app/Contents/Frameworks/Base", "/Apps/Example.app/Contents/Frameworks/Bar"])
        fixture.script.refusals[fooPath] = Self.refusal(of: fooPath, remedy: remedy)
        await fixture.loader.load(frameworksAt: frameworks)
        fixture.script.refusals = [:]

        await fixture.loader.applyRemedy()

        #expect(fixture.script.loadedImagePaths == [fooPath] + remedy.imagePathsToLoadFirst + [fooPath])
        #expect(fixture.loader.state == .idle)
        #expect(fixture.loader.hostApplicationURL == URL(fileURLWithPath: "/Apps/Example.app"))
    }

    @Test("a host app the user names is retraced with, the remedy it finds is applied, and later refusals in the window use it")
    func chosenHostApplicationIsUsedForLaterRefusalsInTheWindow() async throws {
        let frameworks = try Self.makeFrameworks(["Foo", "Baz"])
        let fixture = Self.makeFixture(on: Self.frameworkInstanceEngine())
        let fooPath = try Self.imagePath(of: frameworks[0])
        let bazPath = try Self.imagePath(of: frameworks[1])
        fixture.script.refusals[fooPath] = Self.refusal(of: fooPath)
        await fixture.loader.load(frameworksAt: [frameworks[0]])
        fixture.script.retracedRemedy = .init(hostApplicationPath: "/Apps/Host.app", searchPaths: [], imagePathsToLoadFirst: ["/Apps/Host.app/Contents/Frameworks/Bar"])
        fixture.script.refusals = [:]

        await fixture.loader.retry(hostedBy: URL(fileURLWithPath: "/Apps/Host.app"))

        #expect(fixture.script.diagnoseRequests.map(\.hostApplicationPath) == ["/Apps/Host.app"])
        #expect(fixture.script.loadedImagePaths.suffix(2) == ["/Apps/Host.app/Contents/Frameworks/Bar", fooPath])
        #expect(fixture.loader.state == .idle)

        fixture.script.retracedRemedy = nil
        fixture.script.refusals[bazPath] = Self.refusal(of: bazPath)
        await fixture.loader.load(frameworksAt: [frameworks[1]])

        #expect(fixture.script.diagnoseRequests.count == 2)
        #expect(fixture.script.diagnoseRequests.last?.hostApplicationPath == "/Apps/Host.app")
    }

    @Test("a folder the user adds is searched")
    func searchPathIsRetracedWith() async throws {
        let frameworks = try Self.makeFrameworks(["Foo"])
        let fixture = Self.makeFixture(on: Self.frameworkInstanceEngine())
        let fooPath = try Self.imagePath(of: frameworks[0])
        fixture.script.refusals[fooPath] = Self.refusal(of: fooPath)
        await fixture.loader.load(frameworksAt: frameworks)

        await fixture.loader.retry(searching: URL(fileURLWithPath: "/Libraries"))

        #expect(fixture.script.diagnoseRequests.map(\.searchPaths) == [["/Libraries"]])
        #expect(fixture.loader.searchDirectoryURLs == [URL(fileURLWithPath: "/Libraries")])
        guard case .failed = fixture.loader.state else {
            Issue.record("a retrace that finds nothing leaves the refusal on screen: \(fixture.loader.state)")
            return
        }
    }

    // MARK: - Other Engines

    @Test("on another engine a refusal from an earlier version is diagnosed from dyld's message, with no remedies")
    func olderPeerRefusalBecomesAMessageOnlyDiagnosis() async throws {
        let frameworks = try Self.makeFrameworks(["Foo"])
        let engine = RuntimeEngine(source: .localSocket(name: "Injected", identifier: "4242", role: .client), engineID: "FrameworkLoaderTests.\(UUID().uuidString)")
        let fixture = Self.makeFixture(on: engine)
        let fooPath = try FrameworkLoader.executablePath(ofFrameworkAt: frameworks[0], resolvingLinks: false)
        fixture.script.refusals[fooPath] = TextOnlyFailure(text: "dlopen(\(fooPath), 0x0001): tried: '\(fooPath)' (no such file)")

        await fixture.loader.load(frameworksAt: frameworks)

        guard case .failed(let failure) = fixture.loader.state else {
            Issue.record("not failed: \(fixture.loader.state)")
            return
        }
        #expect(failure.diagnosis.isFromMessageOnly)
        #expect(failure.diagnosis.failure.kind == .imageNotFound)
        #expect(!failure.offersRemedies)
        #expect(!fixture.loader.showsPageInEmptyPanes)
    }

    // MARK: - The Instance Going Away

    @Test("an instance that goes away during a load shows that it stopped, and nothing is loaded again by itself")
    func instanceStopDuringALoadShowsInstanceStoppedWithoutRetrying() async throws {
        let frameworks = try Self.makeFrameworks(["Foo", "Bar"])
        let fixture = Self.makeFixture(on: Self.frameworkInstanceEngine())
        let fooPath = try Self.imagePath(of: frameworks[0])
        fixture.script.refusals[fooPath] = URLError(.networkConnectionLost)

        await fixture.loader.load(frameworksAt: frameworks)

        #expect(fixture.loader.state == .instanceStopped(.init(frameworkURLs: frameworks, interruptedFrameworkURL: frameworks[0])))
        #expect(fixture.script.loadedImagePaths == [fooPath])
        #expect(fixture.loader.showsPageInEmptyPanes)
    }

    @Test("Load Again loads every framework the window asked for")
    func loadAgainReloadsEveryRequestedFramework() async throws {
        let frameworks = try Self.makeFrameworks(["Foo", "Bar"])
        let fixture = Self.makeFixture(on: Self.frameworkInstanceEngine())
        let fooPath = try Self.imagePath(of: frameworks[0])
        fixture.script.refusals[fooPath] = URLError(.networkConnectionLost)
        await fixture.loader.load(frameworksAt: frameworks)
        fixture.script.refusals = [:]

        await fixture.loader.loadAgain()

        #expect(fixture.script.loadedImagePaths == [fooPath, fooPath, try Self.imagePath(of: frameworks[1])])
        #expect(fixture.loader.state == .idle)
    }

    // MARK: - The Window

    @Test("an empty framework instance window shows the pages in its panes, and opens the first framework's image page once loaded")
    func successInAnEmptyWindowOpensTheFirstFrameworksImagePage() async throws {
        let frameworks = try Self.makeFrameworks(["Foo", "Bar"])
        let fixture = Self.makeFixture(on: Self.frameworkInstanceEngine())
        let fooPath = try Self.imagePath(of: frameworks[0])
        fixture.script.refusals[fooPath] = Self.refusal(of: fooPath)

        await fixture.loader.load(frameworksAt: frameworks)
        #expect(fixture.loader.showsPageInEmptyPanes)
        fixture.script.refusals = [:]
        await fixture.loader.retry()

        #expect(!fixture.loader.showsPageInEmptyPanes)
        let entry = fixture.environment.documentState.editorArea.focusedPane.activeTab.currentEntry
        #expect(entry?.content == .image(path: fooPath))
    }

    @Test("a window that already shows something does not show the pages in its panes")
    func windowWithContentKeepsThePagesOutOfItsPanes() async throws {
        let frameworks = try Self.makeFrameworks(["Foo"])
        let fixture = Self.makeFixture(on: Self.frameworkInstanceEngine())
        fixture.environment.documentState.selectionRouter.trigger(.openImage("/A/Shown", in: .focusedTab))
        let fooPath = try Self.imagePath(of: frameworks[0])
        fixture.script.refusals[fooPath] = Self.refusal(of: fooPath)

        await fixture.loader.load(frameworksAt: frameworks)

        guard case .failed = fixture.loader.state else {
            Issue.record("not failed: \(fixture.loader.state)")
            return
        }
        #expect(!fixture.loader.showsPageInEmptyPanes)
    }

    @Test("a framework instance is named after its first framework, counting the others")
    func instanceNameCountsTheOtherFrameworks() {
        let one = RuntimeFrameworkInstance(loading: [URL(fileURLWithPath: "/A/Foo.framework")])
        let three = RuntimeFrameworkInstance(loading: ["Foo", "Bar", "Baz"].map { URL(fileURLWithPath: "/A/\($0).framework") })

        #expect(one.name == "Foo.framework (Isolated)")
        #expect(three.name == "Foo.framework + 2 (Isolated)")
        #expect(three.frameworkURL == URL(fileURLWithPath: "/A/Foo.framework"))
    }
}

#endif
