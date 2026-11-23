import Foundation
import MachOKit
import Testing
@testable import RuntimeViewerCore

/// The parts of the SDK type index (`RuntimeTypeIndex`) that need no SDK:
/// where its cache goes, how older peers' options read, and that a test
/// process never turns it on. Indexing an SDK itself is swift-type-indexing's
/// to test (its opt-in SDK integration tests).
@Suite("RuntimeTypeNames")
struct RuntimeTypeNamesTests {
    // MARK: - Cache location

    @Test("The application, its services and the command-line tool it embeds share one type index directory beside the derived data")
    func applicationProcessesShareTheTypeIndexDirectory() throws {
        let directory = try DerivedDataTestDirectory()
        let applicationURL = directory.url.appendingPathComponent("RuntimeViewer.app", isDirectory: true)
        try Self.makeApplication(at: applicationURL, info: [
            "CFBundleIdentifier": "dev.JH.RuntimeViewer.arm64e",
            RuntimeLocalService.bundleIdentifierInfoDictionaryKey: "dev.JH.RuntimeViewer.arm64e.RuntimeLocalService",
        ])
        let cachesURL = directory.url.appendingPathComponent("Caches", isDirectory: true)

        let fromApplication = RuntimeTypeIndexLocation.cacheDirectoryURL(forBundleAt: applicationURL, cachesDirectoryURL: cachesURL)
        let fromService = RuntimeTypeIndexLocation.cacheDirectoryURL(
            forBundleAt: applicationURL.appendingPathComponent("Contents/XPCServices/RuntimeViewerLocalService.xpc", isDirectory: true),
            cachesDirectoryURL: cachesURL
        )
        // An executable outside a bundle: its main bundle is the directory it is in.
        let fromEmbeddedCommandLineTool = RuntimeTypeIndexLocation.cacheDirectoryURL(
            forBundleAt: applicationURL.appendingPathComponent("Contents/Applications", isDirectory: true),
            cachesDirectoryURL: cachesURL
        )

        let expectedPath = cachesURL.appendingPathComponent("dev.JH.RuntimeViewer.arm64e/TypeIndex").path
        #expect(fromApplication.path == expectedPath)
        #expect(fromService.path == expectedPath)
        #expect(fromEmbeddedCommandLineTool.path == expectedPath)

        let derivedDataLocation = try #require(RuntimeDerivedDataLocation.enclosingApplication(ofBundleAt: applicationURL, cachesDirectoryURL: cachesURL))
        #expect(RuntimeTypeIndexLocation.cacheDirectoryURL(for: derivedDataLocation).path == expectedPath)
    }

    @Test("A command-line tool outside any application keeps its own type index directory")
    func standaloneCommandLineToolKeepsItsOwnDirectory() throws {
        let directory = try DerivedDataTestDirectory()
        let cachesURL = directory.url.appendingPathComponent("Caches", isDirectory: true)
        let toolDirectoryURL = directory.url.appendingPathComponent("bin", isDirectory: true)

        let cacheDirectoryURL = RuntimeTypeIndexLocation.cacheDirectoryURL(forBundleAt: toolDirectoryURL, cachesDirectoryURL: cachesURL)
        #expect(cacheDirectoryURL.path == cachesURL.appendingPathComponent("runtime-viewer-cli/TypeIndex").path)
    }

    @Test("An application that is no RuntimeViewer does not lend a tool inside it its directory")
    func otherApplicationIsWalkedPast() throws {
        let directory = try DerivedDataTestDirectory()
        let applicationURL = directory.url.appendingPathComponent("Other.app", isDirectory: true)
        try Self.makeApplication(at: applicationURL, info: ["CFBundleIdentifier": "com.example.Other"])
        let cachesURL = directory.url.appendingPathComponent("Caches", isDirectory: true)

        let cacheDirectoryURL = RuntimeTypeIndexLocation.cacheDirectoryURL(
            forBundleAt: applicationURL.appendingPathComponent("Contents/MacOS", isDirectory: true),
            cachesDirectoryURL: cachesURL
        )
        #expect(cacheDirectoryURL.path == cachesURL.appendingPathComponent("runtime-viewer-cli/TypeIndex").path)
    }

    @Test("The type index directory is measured, and deleting it removes it at once")
    func measureAndDelete() throws {
        let directory = try DerivedDataTestDirectory()
        let cacheDirectoryURL = directory.url.appendingPathComponent("TypeIndex", isDirectory: true)
        let moduleDirectoryURL = cacheDirectoryURL.appendingPathComponent("maccatalyst/27.2-27C5", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleDirectoryURL, withIntermediateDirectories: true)
        try Data(repeating: 0x2A, count: 64 * 1024).write(to: moduleDirectoryURL.appendingPathComponent("UIKit.json"))

        #expect(RuntimeTypeIndexLocation.allocatedByteCount(at: cacheDirectoryURL) >= 64 * 1024)

        try RuntimeTypeIndexLocation.deleteAll(at: cacheDirectoryURL)
        #expect(!FileManager.default.fileExists(atPath: cacheDirectoryURL.path))
        #expect(RuntimeTypeIndexLocation.allocatedByteCount(at: cacheDirectoryURL) == 0)
        // Nothing to delete is no error: Delete Derived Data runs before any index exists.
        try RuntimeTypeIndexLocation.deleteAll(at: cacheDirectoryURL)
    }

    // MARK: - Options

    /// Generation Options are kept in the user's defaults and sent to peers;
    /// one saved or sent by a build without the type index has no keys for it.
    @Test("Options from before the type index decode with resolving and marking on and waiting off")
    func optionsFromBeforeTheTypeIndexDecodeWithDefaults() throws {
        let savedOptions = Data(#"{"objcHeaderOptions":{"stripOverrides":true},"swiftInterfaceOptions":{"synthesizeOpaqueType":true}}"#.utf8)
        let decodedOptions = try JSONDecoder().decode(RuntimeObjectInterface.GenerationOptions.self, from: savedOptions)
        #expect(decodedOptions.swiftInterfaceOptions.resolvesImportedTypeNames)
        #expect(decodedOptions.swiftInterfaceOptions.synthesizeOpaqueType)
        #expect(decodedOptions.marksSwiftNamesFromAPINotes)
        #expect(!decodedOptions.waitsForTypeIndex)
        #expect(decodedOptions.objcHeaderOptions.stripOverrides)
    }

    @Test("An interactive print does not wait for the type index; MCP's does")
    func onlyNonInteractivePrintsWait() {
        #expect(!RuntimeObjectInterface.GenerationOptions().waitsForTypeIndex)
        #expect(RuntimeObjectInterface.GenerationOptions.mcp.waitsForTypeIndex)
        #expect(RuntimeObjectInterface.GenerationOptions().swiftInterfaceOptions.resolvesImportedTypeNames)
        #expect(RuntimeObjectInterface.GenerationOptions().marksSwiftNamesFromAPINotes)
    }

    // MARK: - Status

    @Test("The status round-trips through JSON and reads as building while a batch is queued on any platform")
    func statusRoundTripsAndReportsBuilding() throws {
        let status = RuntimeTypeIndexStatus(platforms: [
            .init(platformName: "macosx", sdkVersion: "27.2-27C5", phase: .ready, indexedModuleCount: 12),
            .init(platformName: "maccatalyst", sdkVersion: "27.2-27C5", phase: .building(finishedBatchCount: 1, queuedBatchCount: 3), indexedModuleCount: 40),
            .init(platformName: "iphoneos", sdkVersion: nil, phase: .unavailable(.sdkNotInstalled), indexedModuleCount: 0),
        ], cacheByteCount: 123_456)

        let decodedStatus = try JSONDecoder().decode(RuntimeTypeIndexStatus.self, from: JSONEncoder().encode(status))
        #expect(decodedStatus == status)
        #expect(status.isBuilding)
        #expect(!RuntimeTypeIndexStatus.empty.isBuilding)
        #expect(!RuntimeTypeIndexStatus(platforms: [status.platforms[0], status.platforms[2]], cacheByteCount: 0).isBuilding)
    }

    // MARK: - The process switch

    /// A test process prints `__C.` names, reads no SDK and writes nothing
    /// to the application's caches: only the services and the command-line
    /// host turn the index on.
    @Test("A test process leaves the type index off: no batch, the unresolved corpus variant, an empty status")
    func testProcessLeavesTheTypeIndexOff() async throws {
        #expect(!RuntimeTypeNames.isEnabledInThisProcess)
        #expect(RuntimeTypeNamesCorpusVariant.component == "UnresolvedTypeNames")
        guard #available(macOS 13.0, *) else { return }
        let batch = await RuntimeTypeIndex.process.request(RuntimeTypeIndexRequest(platform: .macOS, moduleNames: ["Foundation"], metadataSources: []))
        #expect(batch == nil)
        // Only the platforms: the cache size is that of whatever directory the
        // test runner's bundle maps to, which a real command-line host may use.
        #expect(await RuntimeTypeIndex.process.status().platforms.isEmpty)
    }

    @Test("An image's type index platform is its first build version's")
    func platformNameOfAMacOSImage() throws {
        let foundation = try #require(MachOImage(name: "Foundation"))
        #expect(RuntimeTypeNames.platformName(of: foundation) == "macosx")
    }

    // MARK: - Helpers

    private static func makeApplication(at applicationURL: URL, info: [String: String]) throws {
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL.appendingPathComponent("XPCServices/RuntimeViewerLocalService.xpc", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contentsURL.appendingPathComponent("Applications", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contentsURL.appendingPathComponent("MacOS", isDirectory: true), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: contentsURL.appendingPathComponent("Info.plist"))
    }
}
