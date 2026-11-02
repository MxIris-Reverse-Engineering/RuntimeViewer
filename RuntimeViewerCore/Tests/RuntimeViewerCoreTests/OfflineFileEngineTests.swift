import Foundation
import Testing
import MachOKit
@testable import RuntimeViewerCore

/// A generic type this test bundle declares, for the offline engine to
/// specialize.
struct OfflineSpecializationFixture<Element> {
    var element: Element
    var count: Int
}

/// A Swift struct with stored properties, printed by both engines below.
struct OfflinePrintFixture {
    var name: String
    var identifiers: [Int]
    var isEnabled: Bool
}

/// Offline mode reads a file on disk — a Mach-O file, a bundle, a dyld shared
/// cache — without loading it. These anchor on this test bundle, which is a
/// file this process also has loaded, so the offline engine can be held up
/// against the in-process one, and on this Mac's own dyld shared cache file.
@Suite("Offline files", .serialized)
struct OfflineFileEngineTests {
    /// This test bundle's binary.
    private static let testBundleBinaryPath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return URL(fileURLWithPath: String(cString: fileName)).standardizedFileURL.resolvingSymlinksInPath().path
    }()

    /// The `.xctest` bundle around it.
    private static var testBundleURL: URL {
        var url = URL(fileURLWithPath: testBundleBinaryPath)
        while url.pathExtension != "xctest", url.path != "/" {
            url.deleteLastPathComponent()
        }
        return url
    }

    private static let libobjcPath = "/usr/lib/libobjc.A.dylib"

    private static func flattened(_ runtimeObjects: [RuntimeObject]) -> [RuntimeObject] {
        runtimeObjects.flatMap { [$0] + flattened($0.children) }
    }

    /// An engine reading this test bundle's binary, paired with this Mac's
    /// dyld shared cache.
    private static func pairedTestBundleEngine(engineID: String) async throws -> RuntimeEngine {
        var file = try RuntimeOfflineFile(contentsOf: URL(fileURLWithPath: testBundleBinaryPath))
        file.dependencyCache = .systemDyldSharedCache
        let engine = try RuntimeEngine(reading: file, engineID: engineID)
        try await engine.connect()
        return engine
    }

    // MARK: - What a file is

    @Test("a thin Mach-O file is read whole, as built for macOS")
    func thinMachOFile() throws {
        let file = try RuntimeOfflineFile(contentsOf: URL(fileURLWithPath: Self.testBundleBinaryPath))
        #expect(file.content == .machO(slice: nil))
        #expect(file.platform?.name == "macOS")
        #expect(file.source == .file(name: "anything", url: URL(fileURLWithPath: Self.testBundleBinaryPath)))
    }

    @Test("a fat file is read through the slice this Mac prefers")
    func fatFilePicksPreferredSlice() throws {
        let file = try RuntimeOfflineFile(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
        guard case .machO(let slice?) = file.content else {
            Issue.record("/usr/bin/true was not read as a fat file: \(file.content)")
            return
        }
        #expect(slice.cpuType == 0x0100_000C)
        #expect(slice.cpuSubtype & 0xFF == 2)
    }

    @Test("a file that is neither Mach-O, a bundle nor a dyld shared cache is refused")
    func refusesOtherFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineFileEngineTests-\(UUID().uuidString).txt")
        try Data("not a binary".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: RuntimeOfflineFileError.unsupportedContent(url.standardizedFileURL.resolvingSymlinksInPath())) {
            try RuntimeOfflineFile(contentsOf: url)
        }
    }

    @Test("a bundle lists its executable first and sorts the sidebar under its name")
    func bundleListsExecutableFirst() async throws {
        let file = try RuntimeOfflineFile(contentsOf: Self.testBundleURL)
        #expect(file.content == .bundle)
        let engine = try RuntimeEngine(reading: file, engineID: "OfflineFileEngineTests.bundle")
        try await engine.connect()
        #expect(await engine.imageList.first == Self.testBundleBinaryPath)
        #expect(engine.imageNodes.map(\.name) == [file.displayName])
    }

    // MARK: - Reading the same image both ways

    @Test("the offline engine lists what the in-process engine lists for the same image")
    func listsWhatTheInProcessEngineLists() async throws {
        let offlineEngine = try await Self.pairedTestBundleEngine(engineID: "OfflineFileEngineTests.objects.offline")
        let processEngine = RuntimeEngine(source: .local, engineID: "OfflineFileEngineTests.objects.process")
        try await processEngine.connect()

        let offlineObjects = try await offlineEngine.objects(in: Self.testBundleBinaryPath)
        let processObjects = try await processEngine.objects(in: Self.testBundleBinaryPath)

        let offlineIdentities = Set(Self.flattened(offlineObjects).map { "\($0.kind) \($0.name)" })
        let processIdentities = Set(Self.flattened(processObjects).map { "\($0.kind) \($0.name)" })
        #expect(!offlineIdentities.isEmpty)
        #expect(offlineIdentities.subtracting(processIdentities).isEmpty, "listed offline only: \(offlineIdentities.subtracting(processIdentities).sorted())")
        #expect(processIdentities.subtracting(offlineIdentities).isEmpty, "listed in process only: \(processIdentities.subtracting(offlineIdentities).sorted())")
    }

    @Test("the offline engine prints a Swift struct the way the in-process engine does")
    func printsWhatTheInProcessEnginePrints() async throws {
        let offlineEngine = try await Self.pairedTestBundleEngine(engineID: "OfflineFileEngineTests.print.offline")
        let processEngine = RuntimeEngine(source: .local, engineID: "OfflineFileEngineTests.print.process")
        try await processEngine.connect()

        let offlineFixture = try #require(Self.flattened(try await offlineEngine.objects(in: Self.testBundleBinaryPath)).first { $0.displayName == "OfflinePrintFixture" || $0.displayName.hasSuffix(".OfflinePrintFixture") })
        let processFixture = try #require(Self.flattened(try await processEngine.objects(in: Self.testBundleBinaryPath)).first { $0.displayName == "OfflinePrintFixture" || $0.displayName.hasSuffix(".OfflinePrintFixture") })

        let offlineInterface = try #require(try await offlineEngine.interface(for: offlineFixture, options: .init()))
        let processInterface = try #require(try await processEngine.interface(for: processFixture, options: .init()))
        #expect(offlineInterface.interfaceString.string == processInterface.interfaceString.string)
        #expect(offlineInterface.interfaceString.string.contains("var identifiers"))
    }

    @Test("a generic type is specialized offline, with no metadata to instantiate")
    func specializesOffline() async throws {
        let engine = try await Self.pairedTestBundleEngine(engineID: "OfflineFileEngineTests.specialize")
        try await engine.loadImage(at: "/usr/lib/swift/libswiftCore.dylib")
        let objects = Self.flattened(try await engine.objects(in: Self.testBundleBinaryPath))
        let generic = try #require(objects.first { $0.displayName == "OfflineSpecializationFixture" || $0.displayName.hasSuffix(".OfflineSpecializationFixture") })

        let request = try await engine.specializationRequest(for: generic)
        let parameter = try #require(request.parameters.first)
        let intCandidate = try #require(parameter.candidates.first { $0.displayName == "Int" || $0.displayName == "Swift.Int" })
        let specialized = try await engine.specialize(generic, with: RuntimeSpecializationSelection(arguments: [parameter.name: .candidate(intCandidate)]))

        #expect(specialized.displayName.contains("Int"))
        let interface = try #require(try await engine.interface(for: specialized, options: .init()))
        #expect(interface.interfaceString.string.contains("Int"))
    }

    // MARK: - Dependencies

    @Test("a file's dependencies resolve into the dyld shared cache it is paired with")
    func dependenciesResolveIntoThePairedCache() async throws {
        let engine = try await Self.pairedTestBundleEngine(engineID: "OfflineFileEngineTests.dependencies")
        let dependencies = try await engine.dependencies(for: Self.testBundleBinaryPath, ancestorRpaths: [], mainExecutablePath: Self.testBundleBinaryPath)
        #expect(dependencies.contains { $0.resolvedPath == Self.libobjcPath })
        #expect(await engine.canOpenImage(at: Self.libobjcPath))
    }

    // MARK: - A dyld shared cache

    @Test("an Objective-C class is found by name in the cache image that exports it")
    func findsAClassInTheImageThatExportsIt() async throws {
        let cacheURL = try #require(FullDyldCache.host?.url)
        let file = try RuntimeOfflineFile(contentsOf: cacheURL)
        #expect(file.content == .dyldSharedCache)
        let engine = try RuntimeEngine(reading: file, engineID: "OfflineFileEngineTests.cache")
        try await engine.connect()
        #expect(await engine.imageList.contains(Self.libobjcPath))

        let reference = RuntimeObject(name: "NSObject", displayName: "NSObject", kind: .objc(.type(.class)), imagePath: "", children: [])
        let interface = try #require(try await engine.interface(for: reference, options: .init()))

        #expect(interface.object.imagePath == Self.libobjcPath)
        #expect(interface.interfaceString.string.contains("@interface NSObject"))
    }
}
