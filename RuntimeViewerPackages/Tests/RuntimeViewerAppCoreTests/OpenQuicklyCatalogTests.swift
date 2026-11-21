import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// What an empty editor pane's Open Quickly field finds (`OpenQuicklyCatalog`, proposal
/// `editor-start-page`): the engine's images by name and the objects of its indexed images, ranked
/// as the sidebar's Open Quickly ranks.
@Suite("Open Quickly catalog")
struct OpenQuicklyCatalogTests {
    private static let appKitPath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
    private static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"

    private func names(of entries: [OpenQuicklyCatalog.Entry]) -> [String] {
        entries.map(\.name)
    }

    @Test("an image is found by its file name")
    func imageIsFoundByName() {
        let catalog = OpenQuicklyCatalog(imagePaths: [Self.appKitPath, Self.foundationPath], objectsByImagePath: [:])

        let matches = catalog.matches(for: "AppKit", limit: 10)

        #expect(matches.first.map(\.item) == .image(path: Self.appKitPath))
    }

    @Test("an object of an indexed image is found by its display name, nested ones too")
    func objectsAreFoundNestedOnesToo() {
        let nested = Fixtures.runtimeObject(name: "NSViewNested", imagePath: Self.appKitPath)
        let view = Fixtures.runtimeObject(name: "NSView", imagePath: Self.appKitPath, children: [nested])
        let catalog = OpenQuicklyCatalog(imagePaths: [], objectsByImagePath: [Self.appKitPath: [view]])

        #expect(names(of: catalog.matches(for: "NSView", limit: 10)) == ["NSView", "NSViewNested"])
        #expect(names(of: catalog.matches(for: "Nested", limit: 10)) == ["NSViewNested"])
    }

    @Test("an empty query finds nothing")
    func emptyQueryFindsNothing() {
        let catalog = OpenQuicklyCatalog(imagePaths: [Self.appKitPath], objectsByImagePath: [Self.appKitPath: [Fixtures.runtimeObject(name: "NSView")]])

        #expect(catalog.matches(for: "", limit: 10).isEmpty)
    }

    @Test("a name matched as one run, early and short, comes first, as in the sidebar's Open Quickly")
    func rankingPrefersEarlyShortMatches() {
        let objects = ["NSTableViewRowAction", "NSView", "UIViewController", "MKMapView"].map {
            Fixtures.runtimeObject(name: $0, imagePath: Self.appKitPath)
        }
        let catalog = OpenQuicklyCatalog(imagePaths: [], objectsByImagePath: [Self.appKitPath: objects])

        let matches = names(of: catalog.matches(for: "View", limit: 10))

        #expect(matches.first == "NSView")
        #expect(matches.firstIndex(of: "NSView")! < matches.firstIndex(of: "NSTableViewRowAction")!)
    }

    @Test("at most the limit is returned")
    func atMostTheLimitIsReturned() {
        let objects = (0 ..< 30).map { Fixtures.runtimeObject(name: "View\($0)", imagePath: Self.appKitPath) }
        let catalog = OpenQuicklyCatalog(imagePaths: [], objectsByImagePath: [Self.appKitPath: objects])

        #expect(catalog.matches(for: "View", limit: 5).count == 5)
    }

    @Test("an image tree lists its leaves as images, and an empty group as none")
    func imageTreeLeavesAreImages() {
        let tree = Fixtures.imageTree(rootName: "Dyld Shared Cache", imagePaths: [Self.appKitPath, "/usr/lib/libobjc.A.dylib"])
        let emptyGroup = RuntimeImageNode("Others")

        #expect(Set(tree.leafImagePaths) == [Self.appKitPath, "/usr/lib/libobjc.A.dylib"])
        #expect(emptyGroup.leafImagePaths.isEmpty)
    }
}

/// Reading a catalog from an engine: the objects of indexed images only, without indexing any.
@Suite("Open Quickly catalog loading", .serialized)
@MainActor
struct OpenQuicklyCatalogLoadingTests {
    @Test("loading reads the objects of indexed images only, and indexes nothing")
    func loadingReadsIndexedImagesOnly() async throws {
        let engine = try await TestRuntimeEngine.makeConnectedWithItsFirstReloadOver(engineID: "OpenQuicklyCatalogLoadingTests.indexed")
        try await engine.loadImage(at: TestImages.libobjc)
        let indexedImagePaths = try await engine.indexedImagePathList()
        #expect(indexedImagePaths.contains(engine.canonicalImagePath(TestImages.libobjc)))
        let imagePaths = engine.imageNodes.flatMap(\.leafImagePaths)
        let unindexedImagePath = try #require(imagePaths.first { !indexedImagePaths.contains($0) && engine.canonicalImagePath($0) == $0 })

        let catalog = await OpenQuicklyCatalog.load(imagePaths: imagePaths, from: engine)

        let objectImagePaths = Set(catalog.entries.compactMap { entry -> String? in
            guard case .object(let object) = entry.item else { return nil }
            return object.imagePath
        })
        #expect(objectImagePaths.isSubset(of: Set(indexedImagePaths)))
        #expect(objectImagePaths.contains(engine.canonicalImagePath(TestImages.libobjc)))
        #expect(catalog.entries.contains { $0.item == .image(path: unindexedImagePath) })
        #expect(try await engine.isImageIndexed(path: unindexedImagePath) == false)
    }
}

/// One search over a document's engine (`OpenQuicklySearch`), shared by the start page and the
/// File › Open Quickly… bar.
@Suite("Open Quickly search", .serialized)
@MainActor
struct OpenQuicklySearchTests {
    @Test("a search begun before the engine lists any image reads the catalog again once it does")
    func searchBeforeTheImageTreeReadsAgainLater() async throws {
        let engine = TestRuntimeEngine.makeUnconnected(engineID: "OpenQuicklySearchTests.beforeImageTree")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let search = OpenQuicklySearch(documentState: environment.documentState)
        #expect(engine.imageNodes.isEmpty)

        #expect(await search.matches(for: "libobjc", limit: 10).isEmpty)

        try await engine.connect()
        try await waitUntil { !engine.imageNodes.isEmpty }
        let matches = await search.matches(for: "libobjc", limit: 10)
        #expect(matches.contains { entry in
            if case .image(let path) = entry.item { return path.hasSuffix("libobjc.A.dylib") }
            return false
        })
    }

    @Test("keystrokes before the engine lists any image read nothing")
    func keystrokesBeforeTheImageTreeReadNothing() async throws {
        let engine = TestRuntimeEngine.makeUnconnected(engineID: "OpenQuicklySearchTests.keystrokesBeforeImageTree")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let search = OpenQuicklySearch(documentState: environment.documentState)

        for text in ["l", "li", "lib", "libo", "libob"] {
            #expect(await search.matches(for: text, limit: 10).isEmpty)
        }

        #expect(search.catalogReadCount == 0)
    }

    @Test("a caller already cancelled reads no catalog")
    func cancelledCallerReadsNoCatalog() async throws {
        let engine = try await TestRuntimeEngine.makeConnectedWithItsFirstReloadOver(engineID: "OpenQuicklySearchTests.cancelledCaller")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let search = OpenQuicklySearch(documentState: environment.documentState)
        #expect(!engine.imageNodes.isEmpty)

        // The task cannot start before the test suspends, so it starts cancelled — as the search a
        // dropped term left behind does when it runs only after the search was ended.
        let cancelledMatch = Task { await search.matches(for: "NSObject", limit: 10) }
        cancelledMatch.cancel()

        #expect(await cancelledMatch.value.isEmpty)
        #expect(search.catalogReadCount == 0)
    }
}
