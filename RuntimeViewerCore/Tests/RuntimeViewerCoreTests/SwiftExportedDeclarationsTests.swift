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

    // MARK: - Helpers

    private static func entry(named name: String, kind: RuntimeObjectKind, in objects: [RuntimeObject]) -> RuntimeObject? {
        objects.first { $0.kind == kind && ($0.displayName == name || $0.displayName.hasSuffix(".\(name)")) }
    }
}
