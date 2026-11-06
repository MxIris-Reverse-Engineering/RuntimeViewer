import Foundation
import Testing
@testable import RuntimeViewerCore

/// Offline mode opens a folder — a directory that is no bundle — as it opens
/// a bundle: every executable, dynamic library and bundle below it is listed,
/// and none is opened before it is needed. The folders are made in temporary
/// directories, of `/usr/bin/true` copies and of files holding nothing but a
/// Mach-O header, which is all a listing reads; the class lookup reads this
/// test bundle's own directory.
@Suite("Offline folders", .serialized)
struct OfflineFolderTests {
    // MARK: - What a folder is

    @Test("a directory that names no executable opens as a folder, its platform told by the first image a walk meets")
    func directoryWithoutExecutableIsAFolder() throws {
        let folderURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        try Self.copyTrue(to: folderURL.appendingPathComponent("true"))
        try Self.writeHeaderOnlyMachO(fileType: Self.dynamicLibraryFileType, to: folderURL.appendingPathComponent("lib/libFixture.dylib"))

        let file = try RuntimeOfflineFile(contentsOf: folderURL)

        #expect(file.content == .folder)
        #expect(file.platform?.name == "macOS", "/usr/bin/true, the first image a breadth-first walk meets, is built for macOS")
        #expect(file.displayName == folderURL.lastPathComponent)
    }

    @Test("a directory with an Info.plist that names no executable, as an .xcframework's does, opens as a folder")
    func frameworkCollectionIsAFolder() throws {
        let folderURL = try Self.makeTemporaryDirectory(named: "Fixture.xcframework")
        defer { try? FileManager.default.removeItem(at: folderURL.deletingLastPathComponent()) }
        try Self.writePropertyList(["XCFrameworkFormatVersion": "1.0"], to: folderURL.appendingPathComponent("Info.plist"))
        try Self.writeHeaderOnlyMachO(fileType: Self.dynamicLibraryFileType, to: folderURL.appendingPathComponent("macos-arm64/Fixture.framework/Versions/A/Fixture"))

        let file = try RuntimeOfflineFile(contentsOf: folderURL)

        #expect(file.content == .folder)
    }

    @Test("a folder lists every executable, library and bundle below it by path, and no object file, dSYM, small file, link or other file")
    func folderListsLoadableImagesOnly() async throws {
        let folderURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        try Self.copyTrue(to: folderURL.appendingPathComponent("true"))
        try Self.writeHeaderOnlyMachO(fileType: Self.dynamicLibraryFileType, to: folderURL.appendingPathComponent("lib/libFixture.dylib"))
        try Self.writeHeaderOnlyMachO(fileType: Self.bundleFileType, to: folderURL.appendingPathComponent("PlugIns/Fixture.bundle/Contents/MacOS/Fixture"))
        try Self.writeHeaderOnlyMachO(fileType: Self.objectFileType, to: folderURL.appendingPathComponent("objects/fixture.o"))
        try Self.writeHeaderOnlyMachO(fileType: Self.debugSymbolsFileType, to: folderURL.appendingPathComponent("Fixture.dSYM/Contents/Resources/DWARF/Fixture"))
        try Self.writeHeaderOnlyMachO(fileType: Self.dynamicLibraryFileType, size: 1024, to: folderURL.appendingPathComponent("small/libTiny.dylib"))
        try Data(repeating: 0x41, count: 8192).write(to: folderURL.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: folderURL.appendingPathComponent("links"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folderURL.appendingPathComponent("links/true"), withDestinationURL: folderURL.appendingPathComponent("true"))
        let file = try RuntimeOfflineFile(contentsOf: folderURL)

        let engine = try RuntimeEngine(reading: file, engineID: "OfflineFolderTests.listing")
        try await engine.connect()

        let folderPath = file.url.path
        let imageList = await engine.imageList
        #expect(imageList == [
            folderPath + "/PlugIns/Fixture.bundle/Contents/MacOS/Fixture",
            folderPath + "/lib/libFixture.dylib",
            folderPath + "/true",
        ], "listed: \(imageList)")
        #expect(engine.imageNodes.map(\.name) == [file.displayName], "a folder read alone is one group, under its name")
    }

    /// A temporary directory is under `/var`, which is a link to
    /// `/private/var`: the walk finds the images under the latter, while the
    /// bundle names its executable under the former.
    @Test("a bundle under a linked directory lists its executable first, and once")
    func bundleUnderALinkedDirectoryListsItsExecutableOnce() async throws {
        let bundleURL = try Self.makeTemporaryDirectory(named: "Fixture.app")
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        try Self.writePropertyList(["CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"], to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        try Self.copyTrue(to: bundleURL.appendingPathComponent("Contents/MacOS/Fixture"))
        try Self.writeHeaderOnlyMachO(fileType: Self.dynamicLibraryFileType, to: bundleURL.appendingPathComponent("Contents/Frameworks/libFixture.dylib"))
        let file = try RuntimeOfflineFile(contentsOf: bundleURL)
        #expect(file.content == .bundle)

        let engine = try RuntimeEngine(reading: file, engineID: "OfflineFolderTests.linkedBundle")
        try await engine.connect()

        let imageList = await engine.imageList
        #expect(imageList == [
            file.url.path + "/Contents/MacOS/Fixture",
            file.url.path + "/Contents/Frameworks/libFixture.dylib",
        ], "listed: \(imageList)")
    }

    @Test("a folder holding no executable, library or bundle is refused before anything opens it")
    func folderWithoutImagesIsRefused() throws {
        let folderURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        try Self.writeHeaderOnlyMachO(fileType: Self.objectFileType, to: folderURL.appendingPathComponent("fixture.o"))
        try Data(repeating: 0x41, count: 8192).write(to: folderURL.appendingPathComponent("notes.txt"))

        #expect(throws: RuntimeOfflineFileError.folderWithoutMachOFiles(folderURL.standardizedFileURL.resolvingSymlinksInPath())) {
            try RuntimeOfflineFile(contentsOf: folderURL)
        }
    }

    @Test("a folder has no main executable, so opening one starts no main-executable indexing")
    func folderHasNoMainExecutable() async throws {
        let folderURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        try Self.copyTrue(to: folderURL.appendingPathComponent("true"))
        let engine = try RuntimeEngine(reading: try RuntimeOfflineFile(contentsOf: folderURL), engineID: "OfflineFolderTests.mainExecutable")
        try await engine.connect()

        #expect(try await engine.mainExecutablePath() == "")
    }

    // MARK: - Reading on demand

    @Test("an Objective-C class is found by name in the folder's image that exports it")
    func findsAClassInTheFolderImageThatExportsIt() async throws {
        let file = try RuntimeOfflineFile(contentsOf: URL(fileURLWithPath: Self.testBundleBinaryPath).deletingLastPathComponent())
        #expect(file.content == .folder)
        let engine = try RuntimeEngine(reading: file, engineID: "OfflineFolderTests.objcClass")
        try await engine.connect()

        let className = "_TtC22RuntimeViewerCoreTests23ObjCExportPublicFixture"
        let reference = RuntimeObject(name: className, displayName: className, kind: .objc(.type(.class)), imagePath: "", children: [])
        let interface = try #require(try await engine.interface(for: reference, options: .init()))

        #expect(interface.object.imagePath == Self.testBundleBinaryPath)
    }

    /// The images of a bundle used to be opened when its catalog was made,
    /// each holding a descriptor for good, so a bundle with more images than
    /// the process had descriptors for listed only as many as there were left.
    @Test("a bundle with more images than the process has descriptors for lists every one of them and reads its executable")
    func bundleListsMoreImagesThanDescriptors() async {
        await #expect(processExitsWith: .success) {
            let isListedAndRead = await OfflineFolderTests.listAndReadBundleUnderASmallDescriptorLimit()
            exit(isListedAndRead ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    /// Lowers this process's soft and hard descriptor limits to 256 — the
    /// soft limit alone, CoreFoundation would raise — and opens a bundle of
    /// an executable and 300 libraries. Whether all 301 images are listed and
    /// the executable can be read.
    static func listAndReadBundleUnderASmallDescriptorLimit() async -> Bool {
        var limit = rlimit(rlim_cur: 256, rlim_max: 256)
        guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else { return false }
        do {
            let bundleURL = try makeTemporaryDirectory(named: "Fixture.app")
            defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
            try writePropertyList(["CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"], to: bundleURL.appendingPathComponent("Contents/Info.plist"))
            let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/Fixture")
            try copyTrue(to: executableURL)
            for libraryIndex in 0 ..< 300 {
                try writeHeaderOnlyMachO(fileType: dynamicLibraryFileType, to: bundleURL.appendingPathComponent("Contents/Frameworks/libFixture\(libraryIndex).dylib"))
            }
            let file = try RuntimeOfflineFile(contentsOf: bundleURL)
            let engine = try RuntimeEngine(reading: file, engineID: "OfflineFolderTests.descriptors")
            try await engine.connect()
            guard await engine.imageList.count == 301 else { return false }
            _ = try await engine.objects(in: file.url.path + "/Contents/MacOS/Fixture")
            return true
        } catch {
            return false
        }
    }

    // MARK: - Fixtures

    /// This test bundle's binary, which exports a few Objective-C classes.
    private static let testBundleBinaryPath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return URL(fileURLWithPath: String(cString: fileName)).standardizedFileURL.resolvingSymlinksInPath().path
    }()

    /// `MH_OBJECT`, `MH_DYLIB`, `MH_BUNDLE` and `MH_DSYM` from
    /// `<mach-o/loader.h>`.
    static let objectFileType: UInt32 = 0x1
    static let dynamicLibraryFileType: UInt32 = 0x6
    static let bundleFileType: UInt32 = 0x8
    static let debugSymbolsFileType: UInt32 = 0xA

    /// A new, empty directory of its own under the temporary directory — or,
    /// with `name`, a directory of that name inside one.
    static func makeTemporaryDirectory(named name: String? = nil) throws -> URL {
        var directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineFolderTests-\(UUID().uuidString)")
        if let name {
            directoryURL.appendPathComponent(name)
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    /// A copy of `/usr/bin/true`: a fat executable built for macOS that
    /// defines no Objective-C or Swift types.
    static func copyTrue(to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: destinationURL)
    }

    /// A 64-bit arm64 Mach-O file of `fileType` holding its header and no load
    /// commands, padded with zeros to `size` bytes.
    static func writeHeaderOnlyMachO(fileType: UInt32, size: Int = 4096, to fileURL: URL) throws {
        let headerWords: [UInt32] = [
            0xFEED_FACF, // MH_MAGIC_64
            0x0100_000C, // CPU_TYPE_ARM64
            0, // CPU_SUBTYPE_ARM64_ALL
            fileType,
            0, // ncmds
            0, // sizeofcmds
            0, // flags
            0, // reserved
        ]
        var data = Data()
        for headerWord in headerWords {
            withUnsafeBytes(of: headerWord.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(Data(count: size - data.count))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)
    }

    static func writePropertyList(_ propertyList: [String: String], to fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: fileURL)
    }
}
