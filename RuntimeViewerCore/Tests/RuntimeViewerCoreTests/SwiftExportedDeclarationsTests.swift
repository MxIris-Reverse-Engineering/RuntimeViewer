import Foundation
import Testing
@testable import RuntimeViewerCore

// MARK: - Fixtures

/// Public, so this bundle's export trie lists its descriptor and its public
/// members.
public struct ExportedDeclarationsPublicFixture {
    public init() {}

    public func publicMemberFixture() {}

    private func privateMemberFixture() {}

    /// Not exported, though the type around it is.
    private struct ExportedDeclarationsNestedFixture {}
}

extension ExportedDeclarationsPublicFixture {
    /// The extension's only member, and not exported: the extension goes with
    /// it.
    private func privateExtensionMemberFixture() {}
}

/// Private, so its descriptor symbol is local to this bundle.
private struct ExportedDeclarationsPrivateFixture {
    func memberOfPrivateFixture() {}
}

public protocol ExportedDeclarationsPublicProtocolFixture {
    func publicRequirementFixture()
}

/// The private type's conformance to the public protocol. Its extension has no
/// symbol of its own to judge, so it goes with the type only because the
/// printer knows the type is not exported — the export filter scope the Swift
/// section installs.
extension ExportedDeclarationsPrivateFixture: ExportedDeclarationsPublicProtocolFixture {
    func publicRequirementFixture() {}
}

private protocol ExportedDeclarationsPrivateProtocolFixture {
    func privateRequirementFixture()
}

// MARK: - Tests

/// Which Swift types and protocols an image does not export, and what Print
/// Exported Declarations Only makes of it — anchored on the fixtures above,
/// so nothing depends on what a system version ships. Whether a declaration
/// is exported is MachOSwiftSection's verdict (`ExportStatus`); these check
/// that the engine passes it on and prints by it.
@Suite(.serialized)
struct SwiftExportedDeclarationsTests {
    /// This test bundle's image, where every fixture is declared.
    private static let testBundlePath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return String(cString: fileName)
    }()

    /// One engine for the suite, and the Swift objects it lists for this
    /// bundle.
    private static let sharedBundle = Task<(engine: RuntimeEngine, objects: [RuntimeObject]), any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "SwiftExportedDeclarationsTests")
        try await engine.connect()
        let objects = try await engine.objects(in: testBundlePath)
        return (engine, objects.filter(\.kind.isSwift))
    }

    private static func options(exportedOnly: Bool) -> RuntimeObjectInterface.GenerationOptions {
        var options = RuntimeObjectInterface.GenerationOptions()
        options.swiftInterfaceOptions.printExportedDeclarationsOnly = exportedOnly
        return options
    }

    // MARK: - The sidebar's flag

    @Test("a type or protocol the bundle does not export is marked Not Exported, and one it exports is not", arguments: [
        ("ExportedDeclarationsPrivateFixture", RuntimeObjectKind.swift(.type(.struct)), true),
        ("ExportedDeclarationsPublicFixture", .swift(.type(.struct)), false),
        ("ExportedDeclarationsPrivateProtocolFixture", .swift(.type(.protocol)), true),
        ("ExportedDeclarationsPublicProtocolFixture", .swift(.type(.protocol)), false),
    ])
    func flagFollowsTheExportTrie(name: String, kind: RuntimeObjectKind, isNotExported: Bool) async throws {
        let (_, objects) = try await Self.sharedBundle.value
        let entry = try #require(Self.entry(named: name, kind: kind, in: objects), "\(name) is not listed")

        #expect(entry.properties.contains(.isNotExported) == isNotExported)
    }

    @Test("a nested type the bundle does not export is marked, inside a type it exports")
    func nestedTypeIsMarked() async throws {
        let (_, objects) = try await Self.sharedBundle.value
        let parent = try #require(Self.entry(named: "ExportedDeclarationsPublicFixture", kind: .swift(.type(.struct)), in: objects))
        let nested = try #require(Self.entry(named: "ExportedDeclarationsNestedFixture", kind: .swift(.type(.struct)), in: parent.children), "\(parent.children.map(\.displayName))")

        #expect(nested.properties.contains(.isNotExported))
    }

    /// An extension or a conformance has no descriptor symbol of its own, and
    /// an `@objc` protocol declared in Swift has none at all — not even the
    /// private one `SwiftDeclaredObjCProtocolListTests` declares.
    @Test("no extension, conformance or @objc protocol entry is marked")
    func entriesWithoutAVerdictAreNotMarked() async throws {
        let (_, objects) = try await Self.sharedBundle.value
        let extensionEntries = objects.filter {
            switch $0.kind {
            case .swift(.extension), .swift(.conformance): true
            default: false
            }
        }
        let objcProtocolEntries = objects.filter { $0.kind == .swift(.type(.protocol)) && $0.properties.contains(.isObjCProtocol) }
        let privateObjCProtocol = try #require(Self.entry(named: "SwiftDeclaredObjCProtocolPrivateFixture", kind: .swift(.type(.protocol)), in: objects))

        #expect(!extensionEntries.isEmpty)
        #expect(!objcProtocolEntries.isEmpty)
        for entry in extensionEntries + objcProtocolEntries + [privateObjCProtocol] {
            #expect(!entry.properties.contains(.isNotExported), "\(entry.kind) \(entry.displayName)")
        }
    }

    // MARK: - Print Exported Declarations Only

    @Test("an exported type keeps what the image exports and loses the rest, an emptied extension leaving no blank lines")
    func exportedTypeLosesWhatIsNotExported() async throws {
        let (engine, objects) = try await Self.sharedBundle.value
        let entry = try #require(Self.entry(named: "ExportedDeclarationsPublicFixture", kind: .swift(.type(.struct)), in: objects))

        let everything = try #require(try await engine.interface(for: entry, options: Self.options(exportedOnly: false))).interfaceString.string
        let exportedOnly = try #require(try await engine.interface(for: entry, options: Self.options(exportedOnly: true))).interfaceString.string

        for name in ["publicMemberFixture", "privateMemberFixture", "ExportedDeclarationsNestedFixture", "privateExtensionMemberFixture"] {
            #expect(everything.contains(name), "\(name) is missing with the option off:\n\(everything)")
        }
        #expect(exportedOnly.contains("publicMemberFixture"), "\(exportedOnly)")
        for name in ["privateMemberFixture", "ExportedDeclarationsNestedFixture", "privateExtensionMemberFixture"] {
            #expect(!exportedOnly.contains(name), "\(name) is printed with the option on:\n\(exportedOnly)")
        }
        #expect(!exportedOnly.contains("\n\n\n"), "\(exportedOnly)")
        #expect(!exportedOnly.hasSuffix("\n"), "\(exportedOnly)")
    }

    /// What each prints with the option off: the struct's member and its
    /// conformance's extension, and the protocol's declaration — a private
    /// protocol's requirement has no symbol to name it by.
    @Test("a type or protocol the image does not export prints nothing at all", arguments: [
        ("ExportedDeclarationsPrivateFixture", RuntimeObjectKind.swift(.type(.struct)), ["memberOfPrivateFixture", "ExportedDeclarationsPrivateFixture: RuntimeViewerCoreTests.ExportedDeclarationsPublicProtocolFixture {}"]),
        ("ExportedDeclarationsPrivateProtocolFixture", .swift(.type(.protocol)), ["protocol ExportedDeclarationsPrivateProtocolFixture"]),
    ])
    func unexportedDeclarationPrintsNothing(name: String, kind: RuntimeObjectKind, textsPrintedWithTheOptionOff: [String]) async throws {
        let (engine, objects) = try await Self.sharedBundle.value
        let entry = try #require(Self.entry(named: name, kind: kind, in: objects))

        let everything = try #require(try await engine.interface(for: entry, options: Self.options(exportedOnly: false))).interfaceString
        let exportedOnly = try #require(try await engine.interface(for: entry, options: Self.options(exportedOnly: true))).interfaceString

        for text in textsPrintedWithTheOptionOff {
            #expect(everything.string.contains(text), "\(everything.string)")
        }
        #expect(exportedOnly.isEmpty, "\(exportedOnly.string)")
    }

    @Test("a batch export with the option on writes no file for what prints nothing")
    func batchExportSkipsWhatPrintsNothing() async throws {
        let (engine, _) = try await Self.sharedBundle.value
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftExportedDeclarationsTests-\(UUID().uuidString)", isDirectory: true)
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
                failedObjectNames.append(object.displayName)
            }
        }

        // File names are display names, which carry the module name.
        let swiftDirectory = directory.appendingPathComponent("SwiftInterfaces", isDirectory: true)
        let fileNames = try FileManager.default.contentsOfDirectory(atPath: swiftDirectory.path)
        #expect(fileNames.contains { $0.hasSuffix(".ExportedDeclarationsPublicFixture.swiftinterface") }, "\(fileNames.filter { $0.contains("ExportedDeclarations") })")
        #expect(!fileNames.contains { $0.contains("ExportedDeclarationsPrivate") }, "\(fileNames.filter { $0.contains("ExportedDeclarations") })")
        for fileName in fileNames {
            let contents = try String(contentsOf: swiftDirectory.appendingPathComponent(fileName), encoding: .utf8)
            #expect(!contents.isEmpty, "\(fileName) is empty")
        }
        // Left out, not failed.
        #expect(!failedObjectNames.contains { $0.contains("ExportedDeclarationsPrivate") }, "\(failedObjectNames)")
    }

    // MARK: - Helpers

    private static func entry(named name: String, kind: RuntimeObjectKind, in objects: [RuntimeObject]) -> RuntimeObject? {
        objects.first { $0.kind == kind && ($0.displayName == name || $0.displayName.hasSuffix(".\(name)")) }
    }
}
