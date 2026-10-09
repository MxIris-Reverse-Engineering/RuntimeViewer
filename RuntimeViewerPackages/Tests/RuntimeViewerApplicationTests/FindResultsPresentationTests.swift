import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The Find page's outline rules: which rows show expanded after an update, and which rows are
/// the user's selection in the new tree.
@Suite("Find results presentation")
@MainActor
struct FindResultsPresentationTests {
    /// `Root ▸ Middle ▸ Inner ▸ Leaf`.
    private static func nestedTree() -> FindResultNode {
        let leaf = FindResultFixtures.relationship(named: "Leaf", path: "tree/Middle/Inner")
        let inner = FindResultFixtures.relationship(named: "Inner", path: "tree/Middle", children: [leaf])
        let middle = FindResultFixtures.relationship(named: "Middle", path: "tree", children: [inner])
        return FindResultFixtures.type(FindResultFixtures.object(named: "Root"), hits: []).copying(children: [middle])
    }

    /// A relationship tree under one matched type: `relatedCount` related types, each with one of
    /// its own.
    private static func relationshipTree(relatedCount: Int) -> FindResultNode {
        let related = (0 ..< relatedCount).map { index in
            FindResultFixtures.relationship(named: "Related\(index)", path: "tree", children: [
                FindResultFixtures.relationship(named: "Nested\(index)", path: "tree/Related\(index)"),
            ])
        }
        return FindResultFixtures.type(FindResultFixtures.object(named: "Matched"), hits: []).copying(children: related)
    }

    @Test("every row with children opens, parents first, except a collapsed row and what is beneath it")
    func collapsedRowsStayClosed() throws {
        let tree = Self.nestedTree()
        let middle = try #require(tree.children.first)

        let everything = FindResultsOutline.nodesToExpand(in: [tree], collapsedIdentifiers: [], isRelationshipTree: true)
        #expect(everything.map(\.identifier) == [tree.identifier, middle.identifier, "tree/Middle/Inner"])

        let withMiddleCollapsed = FindResultsOutline.nodesToExpand(in: [tree], collapsedIdentifiers: [middle.identifier], isRelationshipTree: true)
        #expect(withMiddleCollapsed.map(\.identifier) == [tree.identifier])
    }

    /// Decided with the review (PR121.48): a relationship tree is opened fully only while it stays
    /// under about 500 rows; `NSObject`'s descendants alone run to thousands.
    @Test("a relationship tree of more than 500 rows opens its first level only")
    func largeRelationshipTreeOpensItsFirstLevel() {
        let tree = Self.relationshipTree(relatedCount: 300)
        #expect(FindResultsOutline.rowCount(of: [tree]) == 601)

        let nodesToExpand = FindResultsOutline.nodesToExpand(in: [tree], collapsedIdentifiers: [], isRelationshipTree: true)

        #expect(nodesToExpand.map(\.identifier) == [tree.identifier])
    }

    @Test("a relationship tree of 500 rows or fewer opens fully")
    func smallRelationshipTreeOpensFully() {
        let tree = Self.relationshipTree(relatedCount: 249)
        #expect(FindResultsOutline.rowCount(of: [tree]) == 499)

        let nodesToExpand = FindResultsOutline.nodesToExpand(in: [tree], collapsedIdentifiers: [], isRelationshipTree: true)

        #expect(nodesToExpand.count == 250)
    }

    @Test("the types of a text search open however many rows they make")
    func textResultsOpenEveryType() {
        let types = (0 ..< 600).map { index in FindResultFixtures.type("Type\(index)", hitCount: 1) }

        let nodesToExpand = FindResultsOutline.nodesToExpand(in: types, collapsedIdentifiers: [], isRelationshipTree: false)

        #expect(nodesToExpand.count == 600)
    }

    @Test("the selection is found again at any depth, in tree order")
    func selectionIsFoundAtAnyDepth() throws {
        let tree = Self.nestedTree()
        let alpha = FindResultFixtures.type("Alpha", hitCount: 2)
        let selected = FindResultsOutline.nodes(in: [alpha, tree], identifiedBy: ["tree/Middle/Inner", try #require(alpha.children.last).identifier])

        #expect(selected.map(\.identifier) == [try #require(alpha.children.last).identifier, "tree/Middle/Inner"])
        #expect(FindResultsOutline.nodes(in: [alpha, tree], identifiedBy: []).isEmpty)
    }
}

extension FindResultNode {
    /// This row with other children, for building trees by hand.
    fileprivate func copying(children: [FindResultNode]) -> FindResultNode {
        FindResultNode(content: content, children: children, identifier: identifier)
    }
}
