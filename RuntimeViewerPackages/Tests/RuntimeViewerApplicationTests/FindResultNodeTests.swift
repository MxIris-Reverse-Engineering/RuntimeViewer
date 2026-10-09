import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// What a Find result row is to the outline that shows it: when two rows are the same row, and
/// when a row — with everything beneath it — still shows the same.
@Suite("FindResultNode")
@MainActor
struct FindResultNodeTests {
    // MARK: - Identity

    /// `NSOutlineView` keeps a row expanded, and finds its row, only for an item equal to the one
    /// it knows, and every batch of a search used to bring new instances of every row; nodes
    /// compared by pointer, so a batch collapsed the types and lost the selection (PR121.07).
    @Test("two instances of the same row are equal and hash alike, as AppKit needs to keep it expanded")
    func sameRowIsEqual() {
        let first = FindResultFixtures.type("Alpha", hitCount: 1)
        let second = FindResultFixtures.type("Alpha", hitCount: 1)

        #expect(first !== second)
        #expect(first == second)
        #expect(first.hash == second.hash)
        #expect(first != FindResultFixtures.type("Beta", hitCount: 1))
    }

    // MARK: - Content

    /// The outline's adapter skips a row its content comparison calls unchanged, and that
    /// comparison used to look at the number of children alone (PR121.43): the filter bar swapping
    /// which hits a type shows, as many as before, never reached the outline.
    @Test("a type whose hits changed is different content, even with as many hits")
    func contentComparesTheHits() {
        let object = FindResultFixtures.object(named: "Alpha")
        let before = FindResultFixtures.type(object, hits: [FindResultFixtures.hit(in: "Alpha", lineNumber: 1)])
        let after = FindResultFixtures.type(object, hits: [FindResultFixtures.hit(in: "Alpha", lineNumber: 7)])

        #expect(!after.isContentEqual(to: before))
    }

    @Test("a change two levels down is different content")
    func contentComparesEveryLevel() {
        let object = FindResultFixtures.object(named: "Root")
        func tree(grandchildName: String) -> FindResultNode {
            FindResultNode.object(object, children: [
                FindResultFixtures.relationship(named: "First", path: "tree", children: [
                    FindResultFixtures.relationship(named: grandchildName, path: "tree/First"),
                ]),
                FindResultFixtures.relationship(named: "Second", path: "tree"),
            ])
        }

        #expect(!tree(grandchildName: "Swapped").isContentEqual(to: tree(grandchildName: "Original")))
    }

    /// A type compares by identity — `(imagePath, name, kind)` — while its row shows the display
    /// name, which another run can spell differently.
    @Test("a type shown under another display name is different content")
    func contentComparesTheTitle() {
        let shortName = Fixtures.runtimeObject(name: "Outer.Inner", displayName: "Inner", kind: .swift(.type(.protocol)))
        let qualifiedName = Fixtures.runtimeObject(name: "Outer.Inner", displayName: "Outer.Inner", kind: .swift(.type(.protocol)))
        let before = FindResultFixtures.type(shortName, hits: [])
        let after = FindResultFixtures.type(qualifiedName, hits: [])

        #expect(!after.isContentEqual(to: before))
    }

    // MARK: - Context menu

    /// The results' context menu offered Open in New Tab everywhere, an unresolved relationship
    /// row and empty space included, and the item then did nothing (PR121.44).
    @Test("a row opens in a new tab only when it goes somewhere")
    func onlyRowsThatGoSomewhereOpenInNewTab() throws {
        let type = FindResultFixtures.type("Alpha", hitCount: 1)
        #expect(type.canOpenInNewTab)
        #expect(try #require(type.children.first).canOpenInNewTab)
        #expect(FindResultFixtures.relationship(named: "Resolved", path: "tree").canOpenInNewTab)

        let unresolved = FindResultNode(content: .relationship(name: "MissingType", object: nil), identifier: "tree/MissingType")
        #expect(!unresolved.canOpenInNewTab)
    }

    // MARK: - Filtering

    /// The filter bar used to build every row it kept again, each hit's attributed line included,
    /// on every keystroke (PR121.49).
    @Test("the filter returns the rows it does not change: matching hits, and a type it keeps whole")
    func filterKeepsUnchangedRows() throws {
        // Both hits read "- (void)sample;".
        let alpha = FindResultFixtures.type("Alpha", hitCount: 2)

        let kept = try #require(FindViewModel<SidebarRootRoute>.filtered([alpha], by: "sample").first)

        #expect(kept === alpha)
        #expect(kept.children.first === alpha.children.first)
    }

    @Test("a type the filter keeps in part shares its row's appearance and keeps its matching hits")
    func partialFilterSharesTheAppearance() throws {
        let type = FindResultFixtures.type(FindResultFixtures.object(named: "Alpha"), hits: [
            FindResultFixtures.hit(in: "Alpha", lineNumber: 1, lineText: "- (void)first;"),
            FindResultFixtures.hit(in: "Alpha", lineNumber: 2, lineText: "- (void)second;"),
        ])

        let copy = try #require(FindViewModel<SidebarRootRoute>.filtered([type], by: "second").first)

        #expect(copy !== type)
        #expect(copy.identifier == type.identifier)
        #expect(copy.children.count == 1)
        #expect(copy.children.first === type.children.last)
        #expect(copy.appearance.title === type.appearance.title)
    }

    @Test("a row neither matching nor holding a match is dropped")
    func filterDropsWhatDoesNotMatch() {
        #expect(FindViewModel<SidebarRootRoute>.filtered([FindResultFixtures.type("Alpha", hitCount: 1)], by: "absent").isEmpty)
    }

    @Test("a rebuilt tree that shows the same is the same content")
    func sameTreeIsSameContent() {
        let before = FindResultFixtures.type("Alpha", hitCount: 3)
        let after = FindResultFixtures.type("Alpha", hitCount: 3)

        #expect(after !== before)
        #expect(after.isContentEqual(to: before))
    }
}
