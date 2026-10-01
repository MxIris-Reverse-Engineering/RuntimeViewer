import Foundation
import Semantic
import Testing
@testable import RuntimeViewerCore

/// The rules a corpus print follows around nested types, on hand-built
/// prints: a nested type's own definition comes out of its parent's print
/// equal to the definition printed on its own, an entry's nested blocks are
/// the regions of the children the sidebar lists, and its members stay out
/// of them.
@Suite("RuntimeInterfaceCorpusNesting")
struct RuntimeInterfaceCorpusNestingRulesTests {
    private static let imagePath = "/fixture"

    private static let grandchildName = "6Parent5ChildV10GrandchildV"

    private static let childName = "6Parent5ChildV"

    private static let grandchild = RuntimeObject(name: grandchildName, displayName: "Parent.Child.Grandchild", kind: .swift(.type(.struct)), imagePath: imagePath, children: [])

    private static let child = RuntimeObject(name: childName, displayName: "Parent.Child", kind: .swift(.type(.struct)), imagePath: imagePath, children: [grandchild])

    private static let parent = RuntimeObject(name: "6ParentV", displayName: "Parent", kind: .swift(.type(.struct)), imagePath: imagePath, children: [child])

    /// A struct with one `Int` property, and whatever is nested in it first.
    private static func structDefinition(_ name: String, property: String, nesting nested: SemanticString? = nil) -> SemanticString {
        var definition = SemanticString {
            Keyword("struct")
            Standard(" ")
            TypeName(kind: .struct, name)
            Standard(" {\n")
        }
        if let nested {
            definition.append(nested)
            definition.append(Standard("\n\n"))
        }
        definition.append(SemanticString {
            Standard("    ")
            Keyword("var")
            Standard(" ")
            Variable(property)
            Standard(": Int\n}")
        })
        return definition
    }

    /// `string` moved in by `levels`, line by line, the way the printer
    /// indents a definition it prints inside another — inside an atom that
    /// spans lines too. Atoms keep their types and identifiers.
    private static func indented(_ string: SemanticString, levels: Int) -> SemanticString {
        let indentation = String(repeating: "    ", count: levels)
        var result = SemanticString()
        var isAtLineStart = true
        for component in string.components {
            var text = ""
            for character in component.string {
                if isAtLineStart, character != "\n" {
                    text += indentation
                }
                text.append(character)
                isAtLineStart = character == "\n"
            }
            result.append(AtomicComponent(string: text, type: component.type, identifier: component.identifier))
        }
        return result
    }

    private static let grandchildOwnPrint = structDefinition("Grandchild", property: "leaf")

    /// The child printed on its own: the grandchild inline, marked.
    private static let childOwnPrint = structDefinition(
        "Child",
        property: "name",
        nesting: SemanticString { DefinitionRegion(grandchildName, content: indented(grandchildOwnPrint, levels: 1)) }
    )

    /// The parent printed with its nested definitions marked: the child
    /// inline, and the grandchild inside the child.
    private static let parentPrint = structDefinition(
        "Parent",
        property: "value",
        nesting: SemanticString { DefinitionRegion(childName, content: indented(childOwnPrint, levels: 1)) }
    ).frozen()

    @Test("a nested type's definition taken out of its parent's print equals the definition printed on its own", arguments: [childName, grandchildName])
    func ownDefinitionEqualsOwnPrint(name: String) throws {
        let regions = RuntimeInterfaceCorpusNesting.separate(Self.parentPrint, childNames: [Self.childName]).definitionRegions
        let regionsByObject = RuntimeInterfaceCorpusNesting.descendantRegions(of: Self.parent, in: regions)
        let object = try #require(name == Self.childName ? Self.child : Self.grandchild)
        let region = try #require(regionsByObject[object.key])

        let ownDefinition = try #require(RuntimeInterfaceCorpusNesting.ownDefinition(in: Self.parentPrint, region: region))

        let ownPrint = name == Self.childName ? Self.childOwnPrint : Self.grandchildOwnPrint
        #expect(ownDefinition == ownPrint.frozen())
        #expect(ownDefinition.separatingDefinitionRegions() == ownPrint.frozen().separatingDefinitionRegions())
    }

    @Test("an entry's nested blocks are the regions of the children it lists, not the regions further in")
    func nestedRangesAreTheListedChildrenRegions() throws {
        let separated = RuntimeInterfaceCorpusNesting.separate(Self.parentPrint, childNames: [Self.childName])

        let range = try #require(separated.nestedDefinitionRanges.first)
        #expect(separated.nestedDefinitionRanges.count == 1)
        let block = String(decoding: Array(separated.interface.text.utf8)[range], as: UTF8.self)
        #expect(block.hasPrefix("    struct Child {"))
        #expect(block.hasSuffix("    }"))
        #expect(block.contains("struct Grandchild"))
    }

    @Test("a nested type the sidebar does not list as the object's child keeps its lines in the object")
    func unlistedNestedTypeIsNotSkipped() {
        let separated = RuntimeInterfaceCorpusNesting.separate(Self.parentPrint, childNames: [])

        #expect(separated.nestedDefinitionRanges.isEmpty)
        #expect(separated.definitionRegions.regions.count == 2)
    }

    @Test("an object nested in one that did not print inside its parent is printed on its own")
    func descendantOfMissingParentIsNotFound() {
        // The child failed to print inside the parent: only the grandchild's
        // region would be there, at depth 0, which is not where it nests.
        let parentWithoutChildRegion = Self.structDefinition(
            "Parent",
            property: "value",
            nesting: Self.indented(SemanticString { DefinitionRegion(Self.grandchildName, content: Self.grandchildOwnPrint) }, levels: 1)
        ).frozen()
        let regions = RuntimeInterfaceCorpusNesting.separate(parentWithoutChildRegion, childNames: [Self.childName]).definitionRegions

        let regionsByObject = RuntimeInterfaceCorpusNesting.descendantRegions(of: Self.parent, in: regions)

        #expect(regionsByObject.isEmpty)
    }

    @Test("a region lacking the indentation of the level it sits at gives no definition")
    func misindentedRegionGivesNoDefinition() throws {
        // A transformer that wrote a line of the child flush left.
        var misindentedChild = Self.indented(Self.structDefinition("Child", property: "name"), levels: 1)
        misindentedChild.append(Standard("\n// flush left"))
        let print = Self.structDefinition(
            "Parent",
            property: "value",
            nesting: SemanticString { DefinitionRegion(Self.childName, content: misindentedChild) }
        ).frozen()
        let regions = RuntimeInterfaceCorpusNesting.separate(print, childNames: [Self.childName]).definitionRegions
        let region = try #require(RuntimeInterfaceCorpusNesting.descendantRegions(of: Self.parent, in: regions)[Self.child.key])

        #expect(RuntimeInterfaceCorpusNesting.ownDefinition(in: print, region: region) == nil)
    }

    @Test("an object's members are located outside the blocks of its nested types")
    func membersStayOutOfNestedBlocks() throws {
        // The child declares a `name` too, above the parent's own.
        let print = Self.structDefinition(
            "Parent",
            property: "name",
            nesting: SemanticString { DefinitionRegion(Self.childName, content: Self.indented(Self.structDefinition("Child", property: "name"), levels: 1)) }
        ).frozen()
        let separated = RuntimeInterfaceCorpusNesting.separate(print, childNames: [Self.childName])
        let parentPrint = RuntimeInterfaceCorpusPrint(
            object: RuntimeObject(name: "6ParentV", displayName: "Parent", kind: .swift(.type(.struct)), imagePath: Self.imagePath, children: [RuntimeObject(name: Self.childName, displayName: "Parent.Child", kind: .swift(.type(.struct)), imagePath: Self.imagePath, children: [])]),
            interface: separated.interface,
            visibilityRegions: separated.visibilityRegions,
            members: [RuntimeMemberDeclaration(name: "name", kind: .swiftVariable, isStatic: false, declarationText: "name", lineNumber: nil)],
            nestedDefinitionRanges: separated.nestedDefinitionRanges
        )

        let entry = try #require(RuntimeInterfaceCorpusAssembly.entries(from: [parentPrint]).first)

        let member = try #require(entry.members.first)
        let lines = separated.interface.text.components(separatedBy: "\n")
        let lineNumber = try #require(member.lineNumber)
        #expect(lines[lineNumber - 1] == "    var name: Int")
        #expect(lineNumber == lines.count - 1, "located on line \(lineNumber) of \(lines.count)")
    }
}
