import MachOKit
import Foundation
import Testing
@testable import RuntimeViewerCore

// MARK: - Fixtures

/// Public, so an exported symbol of this bundle publishes its class object.
/// Its stored properties are Objective-C ivars too.
public final class ObjCExportPublicFixture: NSObject {
    public var publicIvarFixture = 0
    private var privateIvarFixture = 0
}

/// Private, so no exported symbol publishes its class object.
private final class ObjCExportPrivateFixture: NSObject {
    var ivarOfPrivateFixture = 0
}

/// A pure Swift class — its root is `Swift._SwiftObject` — is in the
/// Objective-C class list too, and has no `_OBJC_CLASS_$_` symbol even when
/// it is public: the case a verdict by symbol name gets wrong.
public final class ObjCExportPublicSwiftRootFixture {
    public init() {}
}

private final class ObjCExportPrivateSwiftRootFixture {}

// MARK: - Tests

/// Which Objective-C classes an image does not export, and what Print
/// Exported Declarations Only makes of it — anchored on the fixtures above,
/// so nothing depends on what a system version ships. Whether a class is
/// exported is MachOObjCSection's verdict on its class object; these check
/// that the engine passes it on and prints by it.
@Suite(.serialized)
struct ObjCExportedDeclarationsTests {
    /// This test bundle's image, where every fixture is declared.
    private static let testBundlePath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return String(cString: fileName)
    }()

    /// One engine for the suite, and every object it lists for this bundle:
    /// the Swift entries are where the agreement test finds the other face of
    /// a Swift class.
    private static let sharedBundle = Task<(engine: RuntimeEngine, objects: [RuntimeObject]), any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "ObjCExportedDeclarationsTests")
        try await engine.connect()
        let objects = try await engine.objects(in: testBundlePath)
        return (engine, objects)
    }

    private static func options(exportedOnly: Bool) -> RuntimeObjectInterface.GenerationOptions {
        var options = RuntimeObjectInterface.GenerationOptions()
        options.objcHeaderOptions.printExportedDeclarationsOnly = exportedOnly
        return options
    }

    // MARK: - The sidebar's flag

    @Test("a class the bundle does not export is marked Not Exported in the Objective-C list, and one it exports is not", arguments: [
        ("ObjCExportPrivateFixture", true),
        ("ObjCExportPublicFixture", false),
        ("ObjCExportPrivateSwiftRootFixture", true),
        ("ObjCExportPublicSwiftRootFixture", false),
    ])
    func flagFollowsTheClassObject(name: String, isNotExported: Bool) async throws {
        let (_, objects) = try await Self.sharedBundle.value
        let entry = try #require(Self.objcClass(named: name, in: objects), "\(name) is not listed")

        #expect(entry.properties.contains(.isNotExported) == isNotExported, "\(entry.name)")
    }

    /// Neither has a symbol of its own to judge — not even the private
    /// `@objc` protocol `SwiftDeclaredObjCProtocolListTests` declares, listed
    /// under its mangled name, nor this bundle's categories on Foundation's
    /// classes.
    @Test("no Objective-C protocol or category entry is marked")
    func protocolsAndCategoriesAreNotMarked() async throws {
        let (_, objects) = try await Self.sharedBundle.value
        let unjudgedEntries = objects.filter { $0.kind == .objc(.type(.protocol)) || $0.kind == .objc(.category(.class)) }

        #expect(unjudgedEntries.contains { $0.name.contains("SwiftDeclaredObjCProtocolPrivateFixture") }, "\(unjudgedEntries.map(\.name))")
        #expect(unjudgedEntries.contains { $0.kind == .objc(.category(.class)) }, "\(unjudgedEntries.map(\.name))")
        for entry in unjudgedEntries {
            #expect(!entry.properties.contains(.isNotExported), "\(entry.kind) \(entry.name)")
        }
    }

    /// MachOObjCSection judges a Swift class's Objective-C entry by its class
    /// object, MachOSwiftSection its Swift entry by its descriptor. Over every
    /// Swift class of this bundle — the dependencies it links statically
    /// included — the two verdicts mark the same classes.
    @Test("a Swift class is marked in the Objective-C list exactly when it is marked in the Swift list")
    func bothFacesOfASwiftClassAgree() async throws {
        let (engine, objects) = try await Self.sharedBundle.value
        let swiftClassEntries = objects.filter { $0.kind == .objc(.type(.class)) && $0.properties.contains(.isSwiftClass) }

        var comparedCount = 0
        var markedCount = 0
        var disagreements: [String] = []
        for objcEntry in swiftClassEntries {
            guard let swiftEntry = try await engine.counterpart(for: objcEntry) else { continue }
            comparedCount += 1
            let isMarkedInObjCList = objcEntry.properties.contains(.isNotExported)
            if isMarkedInObjCList {
                markedCount += 1
            }
            if isMarkedInObjCList != swiftEntry.properties.contains(.isNotExported) {
                disagreements.append("\(objcEntry.name) (Objective-C list: \(isMarkedInObjCList))")
            }
        }

        #expect(comparedCount >= 4, "only \(comparedCount) of \(swiftClassEntries.count) Swift classes have a Swift entry")
        #expect(markedCount >= 2 && markedCount < comparedCount, "\(markedCount) of \(comparedCount) marked")
        #expect(disagreements.isEmpty, "\(disagreements.count) of \(comparedCount) disagree: \(disagreements)")
    }

    // MARK: - Print Exported Declarations Only

    /// A method has no symbol of its own to judge, so `init` stays; an ivar
    /// goes when no exported symbol publishes its offset variable, which this
    /// bundle does for the public property only.
    @Test("an exported class keeps the ivars the image exports and loses the rest")
    func exportedClassLosesTheIvarsNotExported() async throws {
        let (engine, objects) = try await Self.sharedBundle.value
        let entry = try #require(Self.objcClass(named: "ObjCExportPublicFixture", in: objects))

        let everything = try #require(try await engine.interface(for: entry, options: Self.options(exportedOnly: false))).interfaceString.string
        let exportedOnly = try #require(try await engine.interface(for: entry, options: Self.options(exportedOnly: true))).interfaceString.string

        for text in ["publicIvarFixture", "privateIvarFixture", "- (id)init;"] {
            #expect(everything.contains(text), "\(text) is missing with the option off:\n\(everything)")
        }
        for text in ["publicIvarFixture", "- (id)init;"] {
            #expect(exportedOnly.contains(text), "\(text) is missing with the option on:\n\(exportedOnly)")
        }
        #expect(!exportedOnly.contains("privateIvarFixture"), "\(exportedOnly)")
    }

    @Test("a class the image does not export prints nothing at all", arguments: [
        "ObjCExportPrivateFixture",
        "ObjCExportPrivateSwiftRootFixture",
    ])
    func unexportedClassPrintsNothing(name: String) async throws {
        let (engine, objects) = try await Self.sharedBundle.value
        let entry = try #require(Self.objcClass(named: name, in: objects))

        let everything = try #require(try await engine.interface(for: entry, options: Self.options(exportedOnly: false))).interfaceString
        let exportedOnly = try #require(try await engine.interface(for: entry, options: Self.options(exportedOnly: true))).interfaceString

        #expect(everything.string.contains("@interface"), "\(everything.string)")
        #expect(exportedOnly.isEmpty, "\(exportedOnly.string)")
    }

    @Test("a batch export with the option on writes no header for what prints nothing")
    func batchExportSkipsWhatPrintsNothing() async throws {
        let (engine, _) = try await Self.sharedBundle.value
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ObjCExportedDeclarationsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = RuntimeInterfaceExportConfiguration(
            imagePath: Self.testBundlePath,
            imageName: "RuntimeViewerCoreTests",
            directory: directory,
            objcFormat: .directory,
            swiftFormat: .directory,
            generationOptions: Self.options(exportedOnly: true),
            includeMetadata: false
        )
        let reporter = RuntimeInterfaceExportReporter()

        try await engine.exportInterfaces(with: configuration, reporter: reporter)
        var failedObjectNames: [String] = []
        for await event in reporter.events {
            if case .objectFailed(let object, _) = event {
                failedObjectNames.append(object.name)
            }
        }

        // A Swift class's header is named after its mangled Objective-C name.
        let objcDirectory = directory.appendingPathComponent("ObjCHeaders", isDirectory: true)
        let fileNames = try FileManager.default.contentsOfDirectory(atPath: objcDirectory.path)
        let fixtureFileNames = fileNames.filter { $0.contains("ObjCExport") }
        #expect(fixtureFileNames.contains { $0.hasSuffix("ObjCExportPublicFixture.h") }, "\(fixtureFileNames)")
        #expect(fixtureFileNames.contains { $0.hasSuffix("ObjCExportPublicSwiftRootFixture.h") }, "\(fixtureFileNames)")
        #expect(!fixtureFileNames.contains { $0.contains("ObjCExportPrivate") }, "\(fixtureFileNames)")
        for fileName in fixtureFileNames {
            let contents = try String(contentsOf: objcDirectory.appendingPathComponent(fileName), encoding: .utf8)
            #expect(!contents.isEmpty, "\(fileName) is empty")
        }
        // Left out, not failed.
        #expect(!failedObjectNames.contains { $0.contains("ObjCExportPrivate") }, "\(failedObjectNames)")
    }

    // MARK: - Find

    /// The corpus is printed once with everything marked, and a search reads
    /// each entry under the options it carries: its text through the
    /// projection, a member through the projection of its line — what
    /// `searchInterfaces` and `searchMembers` do. So an ivar the option leaves
    /// out is found only while the option is off.
    @Test("Find finds an ivar the option leaves out only while it is off")
    func findFollowsTheOption() async throws {
        let entries = try await Self.fixtureCorpusEntries()
        let entry = try #require(entries.first { $0.object.name.hasSuffix("ObjCExportPublicFixture") })
        let memberIndex = try #require(entry.members.firstIndex { $0.name == "privateIvarFixture" }, "\(entry.members.map(\.name))")

        for exportedOnly in [false, true] {
            let visibility = RuntimeInterfaceVisibility(Self.options(exportedOnly: exportedOnly))
            let projection = try #require(entry.projection(under: visibility), "the entry has no visibility regions")
            let member = entry.member(at: memberIndex, in: projection, projectedLineTable: RuntimeInterfaceLineTable(projection.text.text))

            #expect(projection.text.string.contains("privateIvarFixture") != exportedOnly, "exported only: \(exportedOnly)\n\(projection.text.string)")
            #expect((member != nil) != exportedOnly, "exported only: \(exportedOnly)")
        }
    }

    /// What the corpus visibility suite checks for libobjc and Foundation,
    /// for this bundle's fixtures, with the option off and on: a projected
    /// corpus entry reads as the interface the content pane prints — nothing
    /// at all for a class the image does not export.
    @Test("a projected corpus entry reads as the content pane's interface", arguments: [false, true])
    func projectionMatchesTheDisplayedInterface(exportedOnly: Bool) async throws {
        let (engine, _) = try await Self.sharedBundle.value
        let entries = try await Self.fixtureCorpusEntries()
        let options = Self.options(exportedOnly: exportedOnly)
        let visibility = RuntimeInterfaceVisibility(options)

        #expect(entries.count == 4, "\(entries.map(\.object.name))")
        for entry in entries {
            let displayed = try #require(try await engine.interface(for: entry.object, options: options)).interfaceString
            let projected = entry.projection(under: visibility)?.text ?? entry.interface
            #expect(projected.string == displayed.string, "\(entry.object.name):\n\(projected.string)\n--- displayed ---\n\(displayed.string)")
        }
    }

    /// The fixtures' corpus entries, printed and assembled the way a corpus
    /// build does — for the fixtures alone, as `SwiftExportedDeclarationsTests`
    /// does for its own.
    private static func fixtureCorpusEntries() async throws -> [RuntimeInterfaceCorpusEntry] {
        let (engine, objects) = try await sharedBundle.value
        let section = try #require(await engine.objcSectionFactory.existingSection(for: testBundlePath) as? RuntimeObjCSection<MachOImage>)
        var prints: [RuntimeInterfaceCorpusPrint] = []
        for object in objects where object.kind == .objc(.type(.class)) && object.name.contains("ObjCExport") {
            if let corpusPrint = try await section.corpusPrint(for: object, transformer: .default) {
                prints.append(corpusPrint)
            }
        }
        return RuntimeInterfaceCorpusAssembly.entries(from: prints)
    }

    // MARK: - Helpers

    /// A Swift class's Objective-C name is mangled, and ends with the class's
    /// own name after its length.
    private static func objcClass(named name: String, in objects: [RuntimeObject]) -> RuntimeObject? {
        objects.first { $0.kind == .objc(.type(.class)) && ($0.name == name || $0.name.hasSuffix("\(name.count)\(name)")) }
    }
}
