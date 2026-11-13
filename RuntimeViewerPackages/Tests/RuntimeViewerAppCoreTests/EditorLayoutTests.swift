import Foundation
import Testing
@testable import RuntimeViewerAppCore

/// `EditorLayout` arranges editor panes by Xcode 27.2's rules (proposal `editor-panes`):
/// where New Editor Pane On Right / Below puts a pane, how a close collapses a child split, and the
/// order focus moves in.
@Suite("EditorLayout")
struct EditorLayoutTests {
    private let firstPaneID = EditorPane.ID()
    private let secondPaneID = EditorPane.ID()
    private let thirdPaneID = EditorPane.ID()
    private let fourthPaneID = EditorPane.ID()

    /// Two panes side by side: the first pane with a pane on its right.
    private func sideBySidePair() -> EditorLayout {
        var layout = EditorLayout(pane: firstPaneID)
        layout.insert(secondPaneID, placed: .onRight, relativeTo: firstPaneID)
        return layout
    }

    /// The first pane on the left, the second above the third on the right.
    private func leftPaneBesideStackedPair() -> EditorLayout {
        var layout = sideBySidePair()
        layout.insert(thirdPaneID, placed: .below, relativeTo: secondPaneID)
        return layout
    }

    @Test("a new window holds one pane, side by side")
    func newWindow() {
        let layout = EditorLayout(pane: firstPaneID)

        #expect(layout.orientation == .sideBySide)
        #expect(layout.items == [.pane(firstPaneID)])
    }

    @Test("a pane on the right of the only pane goes after it in the root")
    func paneOnRightOfTheOnlyPane() {
        let layout = sideBySidePair()

        #expect(layout.orientation == .sideBySide)
        #expect(layout.items == [.pane(firstPaneID), .pane(secondPaneID)])
    }

    @Test("a pane below the only pane turns the root instead of nesting")
    func paneBelowTheOnlyPane() {
        var layout = EditorLayout(pane: firstPaneID)

        layout.insert(secondPaneID, placed: .below, relativeTo: firstPaneID)

        #expect(layout.orientation == .stacked)
        #expect(layout.items == [.pane(firstPaneID), .pane(secondPaneID)])
    }

    @Test("a pane across the root wraps its source in a new child split")
    func paneAcrossTheRootWrapsTheSource() {
        let layout = leftPaneBesideStackedPair()

        #expect(layout.orientation == .sideBySide)
        #expect(layout.items == [.pane(firstPaneID), .split([secondPaneID, thirdPaneID])])
    }

    @Test("a pane in a child split's own direction goes right after its source in that split")
    func paneAlongAChildSplit() {
        var layout = leftPaneBesideStackedPair()

        layout.insert(fourthPaneID, placed: .below, relativeTo: secondPaneID)

        #expect(layout.items == [.pane(firstPaneID), .split([secondPaneID, fourthPaneID, thirdPaneID])])
    }

    @Test("a pane across a child split goes into the root after the whole child split")
    func paneAcrossAChildSplit() {
        var layout = leftPaneBesideStackedPair()

        layout.insert(fourthPaneID, placed: .onRight, relativeTo: secondPaneID)

        #expect(layout.items == [.pane(firstPaneID), .split([secondPaneID, thirdPaneID]), .pane(fourthPaneID)])
    }

    @Test("a child split left with one pane collapses into that pane, in its place")
    func closingCollapsesAChildSplit() {
        var layout = leftPaneBesideStackedPair()

        layout.remove(secondPaneID)

        #expect(layout.items == [.pane(firstPaneID), .pane(thirdPaneID)])
    }

    @Test("closing the root's last pane leaves its child split as the root's only item")
    func closingTheLastRootPaneKeepsTheChildSplit() {
        var layout = leftPaneBesideStackedPair()

        layout.remove(firstPaneID)

        #expect(layout.orientation == .sideBySide)
        #expect(layout.items == [.split([secondPaneID, thirdPaneID])])
    }

    @Test("the only pane is never removed")
    func theOnlyPaneStays() {
        var layout = EditorLayout(pane: firstPaneID)

        layout.remove(firstPaneID)

        #expect(layout.items == [.pane(firstPaneID)])
    }

    @Test("changing the orientation turns every split and keeps the arrangement")
    func changingTheOrientationTransposes() {
        var layout = leftPaneBesideStackedPair()

        layout.changeOrientation()

        #expect(layout.orientation == .stacked)
        #expect(layout.items == [.pane(firstPaneID), .split([secondPaneID, thirdPaneID])])
    }

    @Test("panes are listed depth first, the order focus moves in")
    func paneOrder() {
        var layout = leftPaneBesideStackedPair()
        layout.insert(fourthPaneID, placed: .onRight, relativeTo: thirdPaneID)

        #expect(layout.paneIDs == [firstPaneID, secondPaneID, thirdPaneID, fourthPaneID])
    }

    @Test("the next pane after the last one is the first")
    func nextPaneWraps() {
        let layout = leftPaneBesideStackedPair()

        #expect(layout.paneID(after: secondPaneID) == thirdPaneID)
        #expect(layout.paneID(after: thirdPaneID) == firstPaneID)
    }

    @Test("the pane before the first one is the last")
    func previousPaneWraps() {
        let layout = leftPaneBesideStackedPair()

        #expect(layout.paneID(before: secondPaneID) == firstPaneID)
        #expect(layout.paneID(before: firstPaneID) == thirdPaneID)
    }

    @Test("closing a pane hands the focus to its next sibling in the same split")
    func focusGoesToTheNextSibling() {
        var layout = leftPaneBesideStackedPair()
        layout.insert(fourthPaneID, placed: .below, relativeTo: thirdPaneID)

        #expect(layout.paneID(succeeding: secondPaneID) == thirdPaneID)
    }

    @Test("closing the last pane of a split hands the focus to the sibling before it")
    func focusGoesToThePreviousSibling() {
        let layout = leftPaneBesideStackedPair()

        #expect(layout.paneID(succeeding: thirdPaneID) == secondPaneID)
    }

    @Test("a sibling that is a child split takes the focus with its first pane")
    func focusGoesToTheFirstPaneOfASiblingSplit() {
        let layout = leftPaneBesideStackedPair()

        #expect(layout.paneID(succeeding: firstPaneID) == secondPaneID)
    }

    @Test("the only pane has no pane to hand the focus to")
    func theOnlyPaneHasNoSuccessor() {
        let layout = EditorLayout(pane: firstPaneID)

        #expect(layout.paneID(succeeding: firstPaneID) == nil)
    }

    @Test("a pane added to or taken from the root equalizes every split")
    func rootChangesEqualizeEverything() {
        let previousLayout = leftPaneBesideStackedPair()
        var layout = previousLayout

        layout.insert(fourthPaneID, placed: .onRight, relativeTo: firstPaneID)

        #expect(layout.splitsToEqualize(comparedWith: previousLayout) == .all)
    }

    @Test("wrapping a pane into a child split equalizes every split")
    func wrappingEqualizesEverything() {
        let previousLayout = sideBySidePair()
        var layout = previousLayout

        layout.insert(thirdPaneID, placed: .below, relativeTo: secondPaneID)

        #expect(layout.splitsToEqualize(comparedWith: previousLayout) == .all)
    }

    @Test("a pane added inside a child split equalizes that child split alone")
    func childChangesEqualizeTheChild() {
        let previousLayout = leftPaneBesideStackedPair()
        var layout = previousLayout

        layout.insert(fourthPaneID, placed: .below, relativeTo: thirdPaneID)

        #expect(layout.splitsToEqualize(comparedWith: previousLayout) == .children([1]))
    }

    @Test("changing the orientation keeps every size")
    func turningKeepsTheSizes() {
        let previousLayout = leftPaneBesideStackedPair()
        var layout = previousLayout

        layout.changeOrientation()

        #expect(layout.splitsToEqualize(comparedWith: previousLayout) == .none)
    }
}
