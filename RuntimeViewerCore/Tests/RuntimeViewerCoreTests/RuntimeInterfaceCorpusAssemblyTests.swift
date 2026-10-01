import Foundation
import Semantic
import Testing
@testable import RuntimeViewerCore

/// Turning printed objects into corpus entries on hand-built prints: a
/// nested type's block is found in its parent by its own definition one level
/// deeper, the parent's members stay out of it, and a block that cannot be
/// found is left alone.
@Suite("RuntimeInterfaceCorpusAssembly")
struct RuntimeInterfaceCorpusAssemblyTests {
    private static let imagePath = "/fixture"

    private static let child = RuntimeObject(name: "Child", displayName: "Parent.Child", kind: .swift(.type(.struct)), imagePath: imagePath, children: [])

    private static let parent = RuntimeObject(name: "Parent", displayName: "Parent", kind: .swift(.type(.struct)), imagePath: imagePath, children: [child])

    private static func field(_ name: String) -> RuntimeMemberDeclaration {
        RuntimeMemberDeclaration(name: name, kind: .swiftField, isStatic: false, declarationText: name, lineNumber: nil)
    }

    /// `text`, all of it one `standard` span except the names, which are
    /// variable declarations.
    private static func interface(_ text: String, declaring names: [String]) -> FrozenSemanticString {
        var string = SemanticString()
        var remainder = Substring(text)
        for name in names {
            guard let range = remainder.range(of: name) else { break }
            string.append(Standard(String(remainder[..<range.lowerBound])))
            string.append(Variable(name))
            remainder = remainder[range.upperBound...]
        }
        string.append(Standard(String(remainder)))
        return string.frozen()
    }

    private static func objectPrint(_ object: RuntimeObject, _ text: String, declaring names: [String], ownDefinition: String) -> RuntimeInterfaceCorpusPrint {
        RuntimeInterfaceCorpusPrint(
            object: object,
            interface: interface(text, declaring: names),
            visibilityRegions: .empty,
            members: names.map(field),
            ownDefinitionUTF8Length: ownDefinition.utf8.count
        )
    }

    private static let childOwnDefinition = """
    struct Child {
        // Field offset: 0x0
        var name: Int

        var other: Int
    }
    """

    private static let childPrint = objectPrint(
        child,
        childOwnDefinition + "\n\nextension Parent.Child {\n    var extra: Int\n}",
        declaring: ["name", "other"],
        ownDefinition: childOwnDefinition
    )

    /// The parent prints `Child` inline one level deeper — the empty line
    /// inside it stays empty — above its own `name`.
    private static let parentText = """
    struct Parent {
        struct Child {
            // Field offset: 0x0
            var name: Int

            var other: Int
        }
        var name: Int
    }
    """

    @Test("a nested type's block is found in its parent, and the parent's member of the same name is located below it")
    func nestedBlockFound() throws {
        let parentPrint = Self.objectPrint(Self.parent, Self.parentText, declaring: ["name", "other", "name"], ownDefinition: Self.parentText)
        let entries = RuntimeInterfaceCorpusAssembly.entries(from: [
            RuntimeInterfaceCorpusPrint(object: parentPrint.object, interface: parentPrint.interface, visibilityRegions: .empty, members: [Self.field("name")], ownDefinitionUTF8Length: parentPrint.ownDefinitionUTF8Length),
            Self.childPrint,
        ])

        let block = try #require(Self.parentText.range(of: "    struct Child {\n        // Field offset: 0x0\n        var name: Int\n\n        var other: Int\n    }"))
        let blockRange = Self.parentText.utf8.distance(from: Self.parentText.startIndex, to: block.lowerBound) ..< Self.parentText.utf8.distance(from: Self.parentText.startIndex, to: block.upperBound)
        #expect(entries[0].nestedDefinitionRanges == [blockRange])
        #expect(entries[0].members.map(\.lineNumber) == [8])
        #expect(entries[1].nestedDefinitionRanges.isEmpty)
        #expect(entries[1].members.map(\.lineNumber) == [3, 5])
    }

    @Test("a nested type printed differently in its parent is not excluded")
    func mismatchedBlockLeftAlone() {
        let parentText = Self.parentText.replacingOccurrences(of: "var other: Int", with: "var other: Swift.Int")
        let parentPrint = RuntimeInterfaceCorpusPrint(
            object: Self.parent,
            interface: Self.interface(parentText, declaring: ["name", "other", "name"]),
            visibilityRegions: .empty,
            members: [Self.field("name")],
            ownDefinitionUTF8Length: parentText.utf8.count
        )
        let entries = RuntimeInterfaceCorpusAssembly.entries(from: [parentPrint, Self.childPrint])
        #expect(entries[0].nestedDefinitionRanges.isEmpty)
    }

    @Test("a block is only taken where it covers whole lines")
    func blockMustCoverWholeLines() throws {
        let child = RuntimeObject(name: "Keys", displayName: "Parent.Keys", kind: .swift(.type(.enum)), imagePath: Self.imagePath, children: [])
        let parent = RuntimeObject(name: "Parent", displayName: "Parent", kind: .swift(.type(.struct)), imagePath: Self.imagePath, children: [child])
        // `Inner.Keys` prints exactly like `Parent.Keys` one level deeper, so
        // the block's text also occurs inside that line, after four of its
        // eight spaces — and before the real one.
        let parentText = "struct Parent {\n    struct Inner {\n        enum Keys {}\n    }\n    enum Keys {}\n}"
        let childText = "enum Keys {}"
        let entries = RuntimeInterfaceCorpusAssembly.entries(from: [
            RuntimeInterfaceCorpusPrint(object: parent, interface: Self.interface(parentText, declaring: []), visibilityRegions: .empty, members: [], ownDefinitionUTF8Length: parentText.utf8.count),
            RuntimeInterfaceCorpusPrint(object: child, interface: Self.interface(childText, declaring: []), visibilityRegions: .empty, members: [], ownDefinitionUTF8Length: childText.utf8.count),
        ])
        let line = try #require(parentText.range(of: "\n    enum Keys {}"))
        let lineStart = parentText.utf8.distance(from: parentText.startIndex, to: line.lowerBound) + 1
        #expect(entries[0].nestedDefinitionRanges == [lineStart ..< lineStart + "    enum Keys {}".utf8.count])
    }
}
