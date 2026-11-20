#if os(macOS)

import Foundation
import Testing
@testable import RuntimeViewerCore

/// The diagnosis of a refused `dlopen`, worked out in this process against
/// frameworks built for each test, with dyld's real message. The frameworks
/// sit in an app's `Contents/Frameworks` and carry the rpath a third-party
/// app's do, `@executable_path/../Frameworks`, which in the test process
/// expands against the test runner — the situation Load Frameworks meets.
@Suite("Image load diagnostician")
struct RuntimeImageLoadDiagnosticianTests {
    private static let appRpaths = ["@executable_path/../Frameworks", "@loader_path/Frameworks"]

    private let diagnostician = RuntimeImageLoadDiagnostician(environment: .currentProcess())

    /// dyld's message for `path`, which must fail to load.
    private func dyldMessage(loading path: String, sourceLocation: SourceLocation = #_sourceLocation) -> String {
        do {
            try DyldUtilities.loadImage(at: path)
            Issue.record("\(path) loaded, but the test needs it to fail", sourceLocation: sourceLocation)
            return ""
        } catch let error as DyldOpenError {
            return error.message ?? ""
        } catch {
            Issue.record(error, sourceLocation: sourceLocation)
            return ""
        }
    }

    private static func canonical(_ path: String) -> String {
        RuntimeImageLoadDiagnostician.canonicalPath(path)
    }

    // MARK: - Loading First

    @Test("A framework missing an @rpath dependency fails, and loading the dependency by its path first lets it load")
    func loadingTheDependencyByAbsolutePathFirstLetsTheLoadSucceed() throws {
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Bar"),
            .init(baseName: "Foo", dependencies: ["Bar"], rpaths: Self.appRpaths),
        ])
        let foo = application.framework("Foo")
        let bar = application.framework("Bar")

        let message = dyldMessage(loading: foo.binaryPath)
        #expect(message.contains("Library not loaded: \(bar.installName)"))

        try DyldUtilities.loadImage(at: bar.binaryPath)
        try DyldUtilities.loadImage(at: foo.binaryPath)
    }

    // MARK: - The Chain and the Search

    @Test("A chain through a dependency that resolves keeps both edges")
    func chainKeepsTheEdgesThatResolved() throws {
        // Top links Middle, which sits in Top's own Frameworks (`@loader_path/Frameworks`)
        // and links Bottom, which is in the app's Frameworks only.
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Bottom"),
            .init(baseName: "Carrier", rpaths: Self.appRpaths),
            .init(baseName: "Middle", dependencies: ["Bottom"], placement: .insideFramework("Carrier")),
            .init(baseName: "Top", dependencies: ["Middle"], rpaths: Self.appRpaths, placement: .insideFramework("Carrier")),
        ])
        let top = application.framework("Top")
        let middle = application.framework("Middle")
        let bottom = application.framework("Bottom")
        // Top's `@loader_path/Frameworks` is its own; put Middle where that reaches.
        let topFrameworks = (top.binaryPath as NSString).deletingLastPathComponent + "/Frameworks"
        try FileManager.default.createDirectory(atPath: topFrameworks, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: topFrameworks + "/\(middle.name).framework", withDestinationPath: middle.bundlePath)

        let message = dyldMessage(loading: top.binaryPath)
        let diagnosis = diagnostician.diagnose(imageAt: top.binaryPath, dyldMessage: message)

        #expect(diagnosis.dependencyChain.map(\.installName) == [middle.installName, bottom.installName])
        #expect(diagnosis.dependencyChain.map(\.isResolved) == [true, false])
        #expect(Self.canonical(diagnosis.dependencyChain[0].imagePath) == Self.canonical(top.binaryPath))
        #expect(Self.canonical(diagnosis.dependencyChain[1].imagePath) == Self.canonical(middle.binaryPath))
    }

    @Test("The rpath rows follow dyld's order: the loader's own, then the dlopen caller's, then the main executable's")
    func rpathRowsFollowDyldOrder() throws {
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Bar"),
            .init(baseName: "Foo", dependencies: ["Bar"], rpaths: Self.appRpaths),
        ])
        let foo = application.framework("Foo")

        let message = dyldMessage(loading: foo.binaryPath)
        let diagnosis = diagnostician.diagnose(imageAt: foo.binaryPath, dyldMessage: message)
        let rows = diagnosis.rpathSearches

        #expect(rows.count >= 2)
        #expect(rows.prefix(2).map(\.rpath) == Self.appRpaths)
        #expect(rows.prefix(2).allSatisfy { $0.role == .loader && $0.ownerImagePath == foo.binaryPath })
        let roleOrder: [RuntimeImageLoadDiagnosis.RpathSearch.Role] = [.loader, .dlopenCaller, .mainExecutable]
        let roleIndices = rows.map { row in roleOrder.firstIndex(of: row.role) ?? 0 }
        #expect(roleIndices == roleIndices.sorted())
        #expect(rows.allSatisfy { $0.outcome == .noSuchFile })

        let mainDirectory = (DyldUtilities.mainExecutablePath() as NSString).deletingLastPathComponent
        let expectedFirstCandidate = URL(fileURLWithPath: mainDirectory + "/../Frameworks/" + String(application.framework("Bar").installName.dropFirst("@rpath/".count))).standardized.path
        #expect(rows.first?.candidatePath == expectedFirstCandidate)
    }

    @Test("An @executable_path rpath on the framework gets the note that it was written for a host app")
    func executablePathRpathGetsTheHostExecutableNote() throws {
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Bar"),
            .init(baseName: "Foo", dependencies: ["Bar"], rpaths: Self.appRpaths),
        ])
        let foo = application.framework("Foo")

        let diagnosis = diagnostician.diagnose(imageAt: foo.binaryPath, dyldMessage: dyldMessage(loading: foo.binaryPath))

        let note = diagnosis.notes.first { $0.kind == .rpathExpectsHostExecutable }
        #expect(note?.imagePath == foo.binaryPath)
        #expect(note?.rpath == "@executable_path/../Frameworks")
    }

    @Test("An image dyld already loaded counts as found by its install name")
    func alreadyLoadedImagesCountAsResolvedByInstallName() throws {
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Bar"),
            .init(baseName: "Foo", dependencies: ["Bar"], rpaths: Self.appRpaths),
        ])
        try DyldUtilities.loadImage(at: application.framework("Bar").binaryPath)

        let environment = RuntimeImageLoadDiagnostician.Environment.currentProcess()
        let context = RuntimeImageLoadDiagnostician.SearchContext(
            mainExecutablePath: environment.mainExecutablePath,
            searchPaths: [],
            loadedImagePathsByInstallName: environment.loadedImagePathsByInstallName()
        )
        let failures = diagnostician.unresolvedEdges(from: application.framework("Foo").binaryPath, in: context)

        #expect(failures.isEmpty)
    }

    // MARK: - Remedy

    @Test("The host app is inferred from the framework's path, and its Frameworks are loaded first, dependencies before dependents")
    func remedyLoadsTheHostsFrameworksDependenciesFirst() throws {
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Base"),
            .init(baseName: "Layer", dependencies: ["Base"], rpaths: Self.appRpaths),
            .init(baseName: "Foo", dependencies: ["Layer"], rpaths: Self.appRpaths),
        ])
        let foo = application.framework("Foo")
        let layer = application.framework("Layer")
        let base = application.framework("Base")

        let diagnosis = diagnostician.diagnose(imageAt: foo.binaryPath, dyldMessage: dyldMessage(loading: foo.binaryPath))

        let remedy = try #require(diagnosis.remedy)
        #expect(remedy.hostApplicationPath == application.applicationPath)
        #expect(remedy.imagePathsToLoadFirst.map(Self.canonical) == [base.binaryPath, layer.binaryPath].map(Self.canonical))
        let note = diagnosis.notes.first { $0.kind == .dependencyInHostApplication }
        #expect(note?.hostApplicationPath == application.applicationPath)

        for imagePath in remedy.imagePathsToLoadFirst {
            try DyldUtilities.loadImage(at: imagePath)
        }
        try DyldUtilities.loadImage(at: foo.binaryPath)
    }

    @Test("There is no remedy when a dependency is nowhere to be found")
    func noRemedyWhenSomethingStaysUnresolved() throws {
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Bar", placement: .outside("Elsewhere")),
            .init(baseName: "Foo", dependencies: ["Bar"], rpaths: Self.appRpaths),
        ])
        let foo = application.framework("Foo")

        let diagnosis = diagnostician.diagnose(imageAt: foo.binaryPath, dyldMessage: dyldMessage(loading: foo.binaryPath))

        #expect(diagnosis.failure.kind == .imageNotFound)
        #expect(diagnosis.remedy == nil)
    }

    @Test("A search path is searched after the rpath stack and makes a remedy")
    func searchPathActsAsAnExtraRpath() throws {
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Bar", placement: .outside("Elsewhere")),
            .init(baseName: "Foo", dependencies: ["Bar"], rpaths: Self.appRpaths, placement: .outside("Loose")),
        ])
        let foo = application.framework("Foo")
        let bar = application.framework("Bar")
        let searchPath = try #require(application.outsideDirectories["Elsewhere"])
        let fooFolder = try #require(application.outsideDirectories["Loose"])

        let message = dyldMessage(loading: foo.binaryPath)
        #expect(diagnostician.diagnose(imageAt: foo.binaryPath, dyldMessage: message).remedy == nil)

        let diagnosis = diagnostician.diagnose(imageAt: foo.binaryPath, dyldMessage: message, searchPaths: [searchPath])

        let remedy = try #require(diagnosis.remedy)
        #expect(remedy.hostApplicationPath == nil)
        #expect(remedy.searchPaths == [searchPath, fooFolder])
        #expect(remedy.imagePathsToLoadFirst.map(Self.canonical) == [Self.canonical(bar.binaryPath)])
    }

    @Test("Frameworks copied out of their app into one folder find each other there, with no search path added")
    func dependencyBesideTheFrameworkMakesARemedy() throws {
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Base", placement: .outside("Copied")),
            .init(baseName: "Layer", dependencies: ["Base"], rpaths: Self.appRpaths, placement: .outside("Copied")),
            .init(baseName: "Foo", dependencies: ["Layer"], rpaths: Self.appRpaths, placement: .outside("Copied")),
        ])
        let foo = application.framework("Foo")
        let layer = application.framework("Layer")
        let base = application.framework("Base")
        let folder = try #require(application.outsideDirectories["Copied"])

        let diagnosis = diagnostician.diagnose(imageAt: foo.binaryPath, dyldMessage: dyldMessage(loading: foo.binaryPath))

        let remedy = try #require(diagnosis.remedy)
        #expect(remedy.hostApplicationPath == nil)
        #expect(remedy.searchPaths == [folder])
        #expect(remedy.imagePathsToLoadFirst.map(Self.canonical) == [base.binaryPath, layer.binaryPath].map(Self.canonical))

        for imagePath in remedy.imagePathsToLoadFirst {
            try DyldUtilities.loadImage(at: imagePath)
        }
        try DyldUtilities.loadImage(at: foo.binaryPath)
    }

    @Test("The folder holding an image is the one its nearest framework bundle is in, or the image's own")
    func folderHoldingImageIsTheNearestFrameworksFolder() {
        #expect(RuntimeImageLoadDiagnosis.folderHoldingImage(at: "/Copied/Frameworks/Foo.framework/Versions/A/Foo") == "/Copied/Frameworks")
        #expect(RuntimeImageLoadDiagnosis.folderHoldingImage(at: "/Copied/Foo.framework/Versions/A/Frameworks/Bar.framework/Versions/A/Bar") == "/Copied/Foo.framework/Versions/A/Frameworks")
        #expect(RuntimeImageLoadDiagnosis.folderHoldingImage(at: "/Copied/Foo.framework/Foo") == "/Copied")
        #expect(RuntimeImageLoadDiagnosis.folderHoldingImage(at: "/Copied/lib/libfoo.dylib") == "/Copied/lib")
    }

    @Test("A chosen host app stands in for the main executable")
    func chosenHostApplicationStandsInForTheMainExecutable() throws {
        let host = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Bar"),
        ])
        // Foo is outside any app and links the host's Bar under the same name.
        let loose = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeViewerImageLoadFixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        let bar = host.framework("Bar")
        let fooPath = loose.appendingPathComponent("Foo\(bar.name).dylib").path
        let source = loose.appendingPathComponent("foo.c")
        try "extern int \(bar.name)_value(void);\nint foo_\(bar.name)_value(void) { return \(bar.name)_value(); }\n".write(to: source, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["clang", "-dynamiclib", "-arch", "arm64", "-o", fooPath, source.path, bar.binaryPath, "-Wl,-rpath,@executable_path/../Frameworks"]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)

        let message = dyldMessage(loading: fooPath)
        #expect(diagnostician.diagnose(imageAt: fooPath, dyldMessage: message).remedy == nil)

        let diagnosis = diagnostician.diagnose(imageAt: fooPath, dyldMessage: message, hostApplicationPath: host.applicationPath)

        let remedy = try #require(diagnosis.remedy)
        #expect(remedy.hostApplicationPath == host.applicationPath)
        #expect(remedy.imagePathsToLoadFirst.map(Self.canonical) == [Self.canonical(bar.binaryPath)])
    }

    // MARK: - Other Failures

    @Test("A missing symbol names the image it was expected in and offers no remedy")
    func symbolNotFoundHasNoRemedy() throws {
        // Foo and Bar sit side by side in Holder's Frameworks, and Foo's rpath
        // reaches Bar there; Bar is built again without the symbol Foo calls.
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Holder"),
            .init(baseName: "Bar", placement: .insideFramework("Holder"), exportsExtraSymbol: true, losesExtraSymbolAfterLinking: true),
            .init(baseName: "Foo", dependencies: ["Bar"], rpaths: ["@loader_path/../../.."], placement: .insideFramework("Holder"), usesExtraSymbolOf: ["Bar"]),
        ])
        let foo = application.framework("Foo")
        let bar = application.framework("Bar")

        let message = dyldMessage(loading: foo.binaryPath)
        let diagnosis = diagnostician.diagnose(imageAt: foo.binaryPath, dyldMessage: message)

        #expect(diagnosis.failure.kind == .symbolNotFound)
        #expect(diagnosis.failure.symbolName == "_\(bar.name)_extra")
        #expect(diagnosis.remedy == nil)
        let note = diagnosis.notes.first { $0.kind == .symbolMissingFromImage }
        #expect(note.map { Self.canonical($0.imagePath ?? "") } == Self.canonical(bar.binaryPath))
    }

    @Test("An image without this process's architecture is incompatible, with its architectures in a note")
    func architectureMismatchIsDiagnosed() throws {
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Intel", architecture: "x86_64"),
        ])
        let intel = application.framework("Intel")

        let diagnosis = diagnostician.diagnose(imageAt: intel.binaryPath, dyldMessage: dyldMessage(loading: intel.binaryPath))

        #expect(diagnosis.failure.kind == .incompatibleImage)
        let note = diagnosis.notes.first { $0.kind == .architectureMismatch }
        #expect(note?.architectures == ["x86_64"])
        #expect(diagnosis.remedy == nil)
        #expect(diagnosis.processArchitecture?.hasPrefix("arm64") == true)
    }

    // MARK: - The Resolver

    @Test("An rpath at @loader_path expands against the image that carries it, not the image being resolved")
    func resolutionExpandsLoaderPathAgainstTheRpathsOwner() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeViewerImageLoadFixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ownerDirectory = directory.appendingPathComponent("Owner").path
        let loaderDirectory = directory.appendingPathComponent("Loader").path
        try FileManager.default.createDirectory(atPath: ownerDirectory + "/Libraries", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: loaderDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: ownerDirectory + "/Libraries/libTarget.dylib", contents: Data())

        let resolution = DylibPathResolver(isSharedCacheImage: { _ in false }).resolution(
            of: "@rpath/libTarget.dylib",
            loadedBy: loaderDirectory + "/libLoader.dylib",
            rpathStack: [
                .init(rpath: "@loader_path/Libraries", ownerImagePath: loaderDirectory + "/libLoader.dylib", role: .loader),
                .init(rpath: "relative/ignored", ownerImagePath: loaderDirectory + "/libLoader.dylib", role: .loader),
                .init(rpath: "@loader_path/Libraries", ownerImagePath: ownerDirectory + "/libOwner.dylib", role: .loader),
            ],
            mainExecutablePath: "/nonexistent/Main"
        )

        #expect(resolution.resolvedPath == ownerDirectory + "/Libraries/libTarget.dylib")
        #expect(resolution.attempts.map(\.candidatePath) == [
            loaderDirectory + "/Libraries/libTarget.dylib",
            ownerDirectory + "/Libraries/libTarget.dylib",
        ])
        #expect(resolution.attempts.map(\.exists) == [false, true])
    }
}

#endif
