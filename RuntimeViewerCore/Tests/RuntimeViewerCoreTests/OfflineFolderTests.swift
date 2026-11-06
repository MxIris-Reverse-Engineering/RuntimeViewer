import Foundation
import Testing
import MachODependencies
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

    // MARK: - The apps in a folder

    /// `@executable_path` names the directory of the executable a process
    /// was started from, and a folder of several apps has several: a library
    /// in one app is loaded by that app's.
    @Test("a library of an app in a folder resolves an @executable_path dependency against that app's executable")
    func executablePathExpandsAgainstTheImagesOwnApplication() async throws {
        let folderURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        try Self.makeApplication(named: "Bar", in: folderURL)
        try Self.makeApplication(named: "Foo", in: folderURL)
        let frameworkInstallName = "@executable_path/../Frameworks/X.framework/Versions/A/X"
        try Self.writeHeaderOnlyMachO(fileType: Self.dynamicLibraryFileType, to: folderURL.appendingPathComponent("Foo.app/Contents/Frameworks/X.framework/Versions/A/X"))
        try Self.writeHeaderOnlyMachO(fileType: Self.dynamicLibraryFileType, loadingLibrariesNamed: [frameworkInstallName], to: folderURL.appendingPathComponent("Foo.app/Contents/Frameworks/Y.framework/Versions/A/Y"))
        let file = try RuntimeOfflineFile(contentsOf: folderURL)
        let engine = try RuntimeEngine(reading: file, engineID: "OfflineFolderTests.executablePath")
        try await engine.connect()

        let dependencies = try await engine.dependencies(
            for: file.url.path + "/Foo.app/Contents/Frameworks/Y.framework/Versions/A/Y",
            ancestorRpaths: [],
            mainExecutablePath: try await engine.mainExecutablePath()
        )

        let resolvedPaths = dependencies.filter { $0.installName == frameworkInstallName }.map(\.resolvedPath)
        #expect(resolvedPaths == [file.url.path + "/Foo.app/Contents/Frameworks/X.framework/Versions/A/X"])
    }

    /// An app's executable links its frameworks the way Xcode builds them:
    /// `@rpath/X.framework/X`, with `@executable_path/../Frameworks` as its run
    /// path. Resolved on disk, that names the framework through `..` and the
    /// framework's two symbolic links, while the catalog lists the file the
    /// links lead to, so the dependency walk found nothing to open.
    @Test("a framework an app links through its run path resolves to the file the catalog lists")
    func runPathFrameworkResolvesToTheListedFile() async throws {
        let folderURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let bundleURL = folderURL.appendingPathComponent("Foo.app")
        try Self.writePropertyList(["CFBundleExecutable": "Foo", "CFBundlePackageType": "APPL"], to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        try Self.writeHeaderOnlyMachO(
            fileType: Self.executableFileType,
            loadingLibrariesNamed: ["@rpath/X.framework/X"],
            runPaths: ["@executable_path/../Frameworks"],
            to: bundleURL.appendingPathComponent("Contents/MacOS/Foo")
        )
        let frameworkURL = bundleURL.appendingPathComponent("Contents/Frameworks/X.framework")
        try Self.writeHeaderOnlyMachO(fileType: Self.dynamicLibraryFileType, to: frameworkURL.appendingPathComponent("Versions/A/X"))
        try FileManager.default.createSymbolicLink(atPath: frameworkURL.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: frameworkURL.appendingPathComponent("X").path, withDestinationPath: "Versions/Current/X")
        let file = try RuntimeOfflineFile(contentsOf: bundleURL)
        let engine = try RuntimeEngine(reading: file, engineID: "OfflineFolderTests.runPath")
        try await engine.connect()

        let executablePath = file.url.path + "/Contents/MacOS/Foo"
        let dependencies = try await engine.dependencies(for: executablePath, ancestorRpaths: [], mainExecutablePath: try await engine.mainExecutablePath())

        let frameworkPath = file.url.path + "/Contents/Frameworks/X.framework/Versions/A/X"
        #expect(dependencies.map(\.resolvedPath) == [frameworkPath])
        #expect(await engine.canOpenImage(at: frameworkPath))
    }

    @Test("an image of an app extension is loaded by the extension's executable, not the app's around it")
    func appExtensionImageRunsInTheExtensionsProcess() throws {
        let folderURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        try Self.makeApplication(named: "Foo", in: folderURL)
        try Self.makeApplication(named: "Extension", extension: "appex", in: folderURL.appendingPathComponent("Foo.app/Contents/PlugIns"))
        try Self.writeHeaderOnlyMachO(fileType: Self.dynamicLibraryFileType, to: folderURL.appendingPathComponent("Foo.app/Contents/PlugIns/Extension.appex/Contents/Frameworks/libExtension.dylib"))
        try Self.writeHeaderOnlyMachO(fileType: Self.dynamicLibraryFileType, to: folderURL.appendingPathComponent("lib/libLoose.dylib"))
        let file = try RuntimeOfflineFile(contentsOf: folderURL)
        let catalog = try RuntimeFileImageCatalog(file: file)
        let folderPath = file.url.path

        #expect(catalog.mainExecutablePath(forImageAt: folderPath + "/Foo.app/Contents/PlugIns/Extension.appex/Contents/Frameworks/libExtension.dylib")
            == folderPath + "/Foo.app/Contents/PlugIns/Extension.appex/Contents/MacOS/Extension")
        #expect(catalog.mainExecutablePath(forImageAt: folderPath + "/Foo.app/Contents/MacOS/Foo") == folderPath + "/Foo.app/Contents/MacOS/Foo")
        #expect(catalog.mainExecutablePath(forImageAt: folderPath + "/lib/libLoose.dylib") == nil, "a library in no app has no main executable of its own")
    }

    /// The dependency locator matches a framework linked by `@rpath` by its
    /// file name, so the copy of a framework in another app would do — and
    /// it opens every file it is given.
    @Test("an image of an app in a folder looks for its dependencies among that app's images and the images in no app, never another app's")
    func dependencySearchPathsStayInTheImagesApplication() throws {
        let folderURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        for applicationName in ["Bar", "Foo"] {
            try Self.makeApplication(named: applicationName, in: folderURL)
            try Self.writeHeaderOnlyMachO(fileType: Self.dynamicLibraryFileType, to: folderURL.appendingPathComponent("\(applicationName).app/Contents/Frameworks/X.framework/Versions/A/X"))
        }
        try Self.makeApplication(named: "Extension", extension: "appex", in: folderURL.appendingPathComponent("Foo.app/Contents/PlugIns"))
        try Self.writeHeaderOnlyMachO(fileType: Self.dynamicLibraryFileType, to: folderURL.appendingPathComponent("lib/libLoose.dylib"))
        let file = try RuntimeOfflineFile(contentsOf: folderURL)
        let catalog = try RuntimeFileImageCatalog(file: file)
        let folderPath = file.url.path
        let fooSearchPaths = [
            "/Foo.app/Contents/Frameworks/X.framework/Versions/A/X",
            "/Foo.app/Contents/MacOS/Foo",
            "/Foo.app/Contents/PlugIns/Extension.appex/Contents/MacOS/Extension",
            "/lib/libLoose.dylib",
        ].map { DependencySearchPath.machOFile(path: folderPath + $0) }

        #expect(catalog.dependencySearchPaths(forImageAt: folderPath + "/Foo.app/Contents/Frameworks/X.framework/Versions/A/X") == fooSearchPaths)
        #expect(catalog.dependencySearchPaths(forImageAt: folderPath + "/Foo.app/Contents/PlugIns/Extension.appex/Contents/MacOS/Extension") == fooSearchPaths, "an extension looks where the app around it does")
        #expect(catalog.dependencySearchPaths(forImageAt: folderPath + "/lib/libLoose.dylib") == [.machOFile(path: folderPath + "/lib/libLoose.dylib")])
    }

    @Test("every image of an app opened as a bundle looks for its dependencies among all of the app's images")
    func applicationOpenedAsABundleIsOneScope() throws {
        let folderURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        try Self.makeApplication(named: "Foo", in: folderURL)
        try Self.writeHeaderOnlyMachO(fileType: Self.dynamicLibraryFileType, to: folderURL.appendingPathComponent("Foo.app/Contents/Frameworks/X.framework/Versions/A/X"))
        try Self.makeApplication(named: "Extension", extension: "appex", in: folderURL.appendingPathComponent("Foo.app/Contents/PlugIns"))
        let file = try RuntimeOfflineFile(contentsOf: folderURL.appendingPathComponent("Foo.app"))
        #expect(file.content == .bundle)
        let catalog = try RuntimeFileImageCatalog(file: file)
        let bundlePath = file.url.path

        #expect(catalog.dependencySearchPaths(forImageAt: bundlePath + "/Contents/PlugIns/Extension.appex/Contents/MacOS/Extension") == [
            "/Contents/MacOS/Foo",
            "/Contents/Frameworks/X.framework/Versions/A/X",
            "/Contents/PlugIns/Extension.appex/Contents/MacOS/Extension",
        ].map { DependencySearchPath.machOFile(path: bundlePath + $0) })
    }

    // MARK: - Fixtures

    /// `<name>.<extension>` in `directoryURL`: an `Info.plist` naming its
    /// executable, and the executable, a copy of `/usr/bin/true`.
    static func makeApplication(named name: String, extension pathExtension: String = "app", in directoryURL: URL) throws {
        let bundleURL = directoryURL.appendingPathComponent("\(name).\(pathExtension)")
        try writePropertyList(["CFBundleExecutable": name, "CFBundlePackageType": "APPL"], to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        try copyTrue(to: bundleURL.appendingPathComponent("Contents/MacOS/\(name)"))
    }

    /// This test bundle's binary, which exports a few Objective-C classes.
    private static let testBundleBinaryPath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return URL(fileURLWithPath: String(cString: fileName)).standardizedFileURL.resolvingSymlinksInPath().path
    }()

    /// `MH_OBJECT`, `MH_EXECUTE`, `MH_DYLIB`, `MH_BUNDLE` and `MH_DSYM` from
    /// `<mach-o/loader.h>`.
    static let objectFileType: UInt32 = 0x1
    static let executableFileType: UInt32 = 0x2
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

    /// A 64-bit arm64 Mach-O file of `fileType` holding its header and, for
    /// each install name in `libraryInstallNames`, an `LC_LOAD_DYLIB` command,
    /// padded with zeros to `size` bytes — all a listing or a dependency walk
    /// reads.
    static func writeHeaderOnlyMachO(fileType: UInt32, loadingLibrariesNamed libraryInstallNames: [String] = [], runPaths: [String] = [], size: Int = 4096, to fileURL: URL) throws {
        var loadCommands = Data()
        for runPath in runPaths {
            var pathBytes = Array(runPath.utf8) + [0]
            while (12 + pathBytes.count) % 8 != 0 {
                pathBytes.append(0)
            }
            let commandWords: [UInt32] = [
                0x8000_001C, // LC_RPATH
                UInt32(12 + pathBytes.count), // cmdsize
                12, // path.offset, right after the command's fixed part
            ]
            for commandWord in commandWords {
                withUnsafeBytes(of: commandWord.littleEndian) { loadCommands.append(contentsOf: $0) }
            }
            loadCommands.append(contentsOf: pathBytes)
        }
        for libraryInstallName in libraryInstallNames {
            var nameBytes = Array(libraryInstallName.utf8) + [0]
            while (24 + nameBytes.count) % 8 != 0 {
                nameBytes.append(0)
            }
            let commandWords: [UInt32] = [
                0xC, // LC_LOAD_DYLIB
                UInt32(24 + nameBytes.count), // cmdsize
                24, // dylib.name.offset, right after the command's fixed part
                2, // dylib.timestamp
                0x1_0000, // dylib.current_version, 1.0.0
                0x1_0000, // dylib.compatibility_version, 1.0.0
            ]
            for commandWord in commandWords {
                withUnsafeBytes(of: commandWord.littleEndian) { loadCommands.append(contentsOf: $0) }
            }
            loadCommands.append(contentsOf: nameBytes)
        }
        let headerWords: [UInt32] = [
            0xFEED_FACF, // MH_MAGIC_64
            0x0100_000C, // CPU_TYPE_ARM64
            0, // CPU_SUBTYPE_ARM64_ALL
            fileType,
            UInt32(runPaths.count + libraryInstallNames.count), // ncmds
            UInt32(loadCommands.count), // sizeofcmds
            0, // flags
            0, // reserved
        ]
        var data = Data()
        for headerWord in headerWords {
            withUnsafeBytes(of: headerWord.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(loadCommands)
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
