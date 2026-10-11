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

    // MARK: - Source Files

    @Test("the engine recovers a discriminator's source file from the image's own names")
    func engineRecoversSourceFile() async throws {
        let engine = try await Self.makeEngine("source-files")
        _ = try await engine.objects(in: Anchors.foundationPath)

        let sourceFiles = try await engine.privateDeclarationSourceFiles(forDiscriminators: ["_12768CA107A31EF2DCE034FD75B541C9"], inImage: Anchors.foundationPath)
        #expect(sourceFiles == ["_12768CA107A31EF2DCE034FD75B541C9": RuntimePrivateDeclarationSourceFile(fileName: "JSONEncoder.swift", moduleName: "Foundation", isSynthesized: false)])
    }

    @Test("an image with no Swift section recovers nothing")
    func imageWithoutSwiftSectionRecoversNothing() async throws {
        let engine = try await Self.makeEngine("source-files-objc")

        let sourceFiles = try await engine.privateDeclarationSourceFiles(forDiscriminators: ["_12768CA107A31EF2DCE034FD75B541C9"], inImage: Anchors.libobjcPath)
        #expect(sourceFiles.isEmpty)
    }
}

/// Types declared in a function or closure body, as SwiftUI declares them (macOS 27.2): listed
/// under the type that declares the function, by the name MachOSwiftSection gives a reader — no
/// modules, no parameter or result types — and marked `isLocalType`. Their private declarations are
/// the declaring function's when it is private, and never the types its signature names.
@Suite("Local types in Swift names", .serialized)
struct RuntimeSwiftLocalTypeTests {
    private static let swiftUIPath = "/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI"

    /// SwiftUI's object list, indexed once for the whole suite: indexing SwiftUI takes long.
    private static let swiftUIObjects = Task<[RuntimeObject], Swift.Error> {
        let engine = RuntimeEngine(source: .local, engineID: "test-local-types")
        try await engine.connect()
        try await engine.loadImage(at: swiftUIPath)
        return try await engine.objects(in: swiftUIPath)
    }

    private static func flattened(_ runtimeObjects: [RuntimeObject]) -> [RuntimeObject] {
        runtimeObjects.flatMap { [$0] + flattened($0.children) }
    }

    @Test("a type's local types each get a row of their own, named after their method")
    func localTypesAreListedApart() async throws {
        let tableDataSource = try #require(Self.flattened(try await Self.swiftUIObjects.value).first { $0.displayName == "SwiftUI.TableDataSource" }, "SwiftUI lists no TableDataSource")
        let visitors = tableDataSource.children.filter { $0.properties.contains(.isLocalType) && $0.displayName.hasPrefix("Visitor #1 in TableDataSource.") }

        #expect(visitors.count >= 6, "\(tableDataSource.children.map(\.displayName))")
        #expect(Set(visitors.map(\.displayName)).count == visitors.count)
        #expect(visitors.contains { $0.displayName == "Visitor #1 in TableDataSource.performDrop(to:)" })
        #expect(!visitors.contains { $0.displayName.contains("->") || $0.displayName.contains("Foundation.") })
    }

    @Test("a local type of a private method reads the method's private declaration")
    func localTypeOfAPrivateMethodReadsTheMethod() async throws {
        let generator = try #require(
            Self.flattened(try await Self.swiftUIObjects.value).first { $0.displayName == "IndexingWrappingGenerator #1 in closure #1 in AccessibilityRotorInfo.readEntryList(_:)" },
            "SwiftUI lists no IndexingWrappingGenerator under the name a reader is shown"
        )

        #expect(generator.properties.contains(.isLocalType))
        #expect(!generator.properties.contains(.isPositionNamedLocalType))
        #expect(generator.privateDeclarations == [RuntimePrivateDeclaration(name: "readEntryList", discriminator: "_030667BFE09FD674B7612731735E240E")])
    }

    /// The `~Copyable` generic parameter of `IndexWrappingVisitor` files its members under an
    /// extension carrying the inverse requirement. While the local type's name lost its function,
    /// that extension named a type nothing else did, and the list showed it as a stray extension
    /// row of its own.
    @Test("the members of a local type's nested generic are no stray extension row")
    func nestedGenericMembersAreNoStrayExtension() async throws {
        let swiftUIObjects = try await Self.swiftUIObjects.value
        let strayExtensions = swiftUIObjects.filter { object in
            guard case .swift(.extension) = object.kind else { return false }
            return object.displayName.contains("IndexWrappingVisitor")
        }
        #expect(strayExtensions.map(\.displayName) == [])
        #expect(Self.flattened(swiftUIObjects).contains { $0.displayName == "IndexWrappingVisitor in IndexingWrappingGenerator #1 in closure #1 in AccessibilityRotorInfo.readEntryList(_:)" })
    }
}
