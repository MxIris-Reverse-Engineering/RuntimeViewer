import Foundation
import Testing
import RuntimeViewerCore

/// A private Swift type is listed under the name the demangler prints without private
/// discriminators, and its discriminators come with it in `privateDeclarations`, read off the
/// demangled name. Foundation's `__JSONEncoder` is declared `fileprivate` in `JSONEncoder.swift`;
/// its discriminator is `md5 -s 'FoundationJSONEncoder.swift'`, uppercased (macOS 26.7 and 27.0).
@Suite("Private declarations of Swift names", .serialized)
struct RuntimeSwiftPrivateDeclarationsTests {
    private enum Anchors {
        static let libobjcPath = "/usr/lib/libobjc.A.dylib"
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
    }

    private static func makeEngine(_ label: String) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: "test-private-declarations-" + label)
        try await engine.connect()
        try await engine.loadImage(at: Anchors.libobjcPath)
        try await engine.loadImage(at: Anchors.foundationPath)
        return engine
    }

    private static func flattened(_ runtimeObjects: [RuntimeObject]) -> [RuntimeObject] {
        runtimeObjects.flatMap { [$0] + flattened($0.children) }
    }

    @Test("a private type is listed under its plain name, with its discriminator beside it")
    func privateTypeListsItsDiscriminatorApart() async throws {
        let engine = try await Self.makeEngine("listing")
        let objects = Self.flattened(try await engine.objects(in: Anchors.foundationPath))

        let jsonEncoder = try #require(objects.first { $0.kind == .swift(.type(.class)) && $0.displayName == "Foundation.__JSONEncoder" })

        #expect(jsonEncoder.privateDeclarations == [RuntimePrivateDeclaration(name: "__JSONEncoder", discriminator: "_12768CA107A31EF2DCE034FD75B541C9")])
    }

    @Test("no listed name spells a discriminator of its own")
    func noNameSpellsItsDiscriminator() async throws {
        let engine = try await Self.makeEngine("spelling")
        let objects = Self.flattened(try await engine.objects(in: Anchors.foundationPath))
        let privateObjects = objects.filter { !$0.privateDeclarations.isEmpty }

        try #require(!privateObjects.isEmpty, "Foundation lists no private Swift type")
        let namesSpellingADiscriminator = privateObjects
            .filter { object in object.privateDeclarations.contains { object.displayName.contains($0.discriminator) } }
            .map(\.displayName)
        #expect(namesSpellingADiscriminator == [])
    }
}
