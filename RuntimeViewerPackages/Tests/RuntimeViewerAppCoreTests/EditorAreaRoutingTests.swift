import Foundation
import Testing
import RxSwift
import RuntimeViewerCrossReferences
@testable import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// How `SelectionRoute`s change `DocumentState.editorArea`, and what follows the focused editor
/// pane (proposal `editor-panes`).
@Suite("Editor area routing")
@MainActor
struct EditorAreaRoutingTests {
    private let firstObject = Fixtures.runtimeObject(name: "First")
    private let secondObject = Fixtures.runtimeObject(name: "Second")
    private let thirdObject = Fixtures.runtimeObject(name: "Third")

    /// A document showing `firstObject` in its only pane.
    private func documentShowingFirstObject() -> DocumentState {
        let documentState = DocumentState()
        documentState.selectionRouter.trigger(.open(firstObject, in: .focusedTab))
        return documentState
    }

    // MARK: - Opening

    @Test("opening in the focused tab records the object on that tab's history")
    func openingInTheFocusedTab() {
        let documentState = documentShowingFirstObject()

        documentState.selectionRouter.trigger(.open(secondObject, in: .focusedTab))

        let activeTab = documentState.editorArea.focusedPane.activeTab
        #expect(activeTab.history.entries.map(\.object) == [firstObject, secondObject])
        #expect(documentState.selectedRuntimeObject == secondObject)
    }

    @Test("opening in a new tab adds an active tab whose history holds the object alone")
    func openingInANewTab() {
        let documentState = documentShowingFirstObject()

        documentState.selectionRouter.trigger(.open(secondObject, in: .newTab))

        let focusedPane = documentState.editorArea.focusedPane
        #expect(focusedPane.tabs.count == 2)
        #expect(focusedPane.activeTabIndex == 1)
        #expect(focusedPane.activeTab.history.entries.map(\.object) == [secondObject])
    }

    @Test("opening in the next pane while there is one pane makes a pane on its right and focuses it")
    func openingInTheNextPaneMakesOne() {
        let documentState = documentShowingFirstObject()
        let firstPaneID = documentState.editorArea.focusedPaneID

        documentState.selectionRouter.trigger(.open(secondObject, in: .nextEditorPane))

        let editorArea = documentState.editorArea
        #expect(editorArea.layout.orientation == .sideBySide)
        #expect(editorArea.layout.paneIDs.first == firstPaneID)
        #expect(editorArea.layout.paneIDs.count == 2)
        #expect(editorArea.focusedPaneID != firstPaneID)
        #expect(editorArea.focusedPane.activeTab.history.entries.map(\.object) == [secondObject])
        #expect(editorArea[firstPaneID]?.activeTab.object == firstObject)
    }

    @Test("opening in the next pane goes to the pane after the focused one, wrapping around")
    func openingInTheNextPaneWraps() {
        let documentState = documentShowingFirstObject()
        let firstPaneID = documentState.editorArea.focusedPaneID
        documentState.selectionRouter.trigger(.newEditorPane(.onRight))

        documentState.selectionRouter.trigger(.open(secondObject, in: .nextEditorPane))

        #expect(documentState.editorArea.focusedPaneID == firstPaneID)
        #expect(documentState.editorArea.focusedPane.activeTab.history.entries.map(\.object) == [firstObject, secondObject])
    }

    // MARK: - Panes

    @Test("a new pane shows the focused pane's object, without its history, and takes the focus")
    func newPaneShowsTheCurrentObject() {
        let documentState = documentShowingFirstObject()
        documentState.selectionRouter.trigger(.open(secondObject, in: .focusedTab))
        let sourcePaneID = documentState.editorArea.focusedPaneID

        documentState.selectionRouter.trigger(.newEditorPane(.below))

        let editorArea = documentState.editorArea
        #expect(editorArea.focusedPaneID != sourcePaneID)
        #expect(editorArea.focusedPane.activeTab.history.entries.map(\.object) == [secondObject])
        #expect(editorArea.layout.orientation == .stacked)
    }

    @Test("a new pane made from an empty tab is empty")
    func newPaneFromAnEmptyTab() {
        let documentState = DocumentState()

        documentState.selectionRouter.trigger(.newEditorPane(.onRight))

        #expect(documentState.editorArea.layout.paneIDs.count == 2)
        #expect(documentState.editorArea.focusedPane.activeTab.object == nil)
    }

    @Test("closing the focused pane hands the focus to its sibling")
    func closingThePaneMovesTheFocus() {
        let documentState = documentShowingFirstObject()
        let firstPaneID = documentState.editorArea.focusedPaneID
        documentState.selectionRouter.trigger(.newEditorPane(.onRight))
        documentState.selectionRouter.trigger(.open(secondObject, in: .focusedTab))

        documentState.selectionRouter.trigger(.closeEditorPane(documentState.editorArea.focusedPaneID))

        #expect(documentState.editorArea.layout.paneIDs == [firstPaneID])
        #expect(documentState.editorArea.focusedPaneID == firstPaneID)
        #expect(documentState.selectedRuntimeObject == firstObject)
    }

    @Test("closing the other panes keeps the focused one")
    func closingTheOtherPanes() {
        let documentState = documentShowingFirstObject()
        documentState.selectionRouter.trigger(.newEditorPane(.onRight))
        documentState.selectionRouter.trigger(.newEditorPane(.below))
        let keptPaneID = documentState.editorArea.focusedPaneID

        documentState.selectionRouter.trigger(.closeOtherEditorPanes)

        #expect(documentState.editorArea.layout.paneIDs == [keptPaneID])
    }

    @Test("closing a pane's last tab closes the pane while there is another")
    func closingTheLastTabClosesThePane() {
        let documentState = documentShowingFirstObject()
        let firstPaneID = documentState.editorArea.focusedPaneID
        documentState.selectionRouter.trigger(.newEditorPane(.onRight))
        let secondPaneTabID = documentState.editorArea.focusedPane.activeTabID

        documentState.selectionRouter.trigger(.closeTab(secondPaneTabID))

        #expect(documentState.editorArea.layout.paneIDs == [firstPaneID])
    }

    @Test("the only tab of the only pane is never closed, and the route is not sent")
    func theOnlyTabStays() {
        let documentState = documentShowingFirstObject()
        var routes: [SelectionRoute] = []
        let subscription = documentState.routeSignal.emitOnNext { routes.append($0) }
        defer { subscription.dispose() }

        documentState.selectionRouter.trigger(.closeTab(documentState.editorArea.focusedPane.activeTabID))

        #expect(documentState.editorArea.focusedPane.tabs.count == 1)
        #expect(routes.isEmpty)
    }

    @Test("closing the only pane empties it: one empty tab in the same pane, and the route is sent")
    func closingTheOnlyPaneEmptiesIt() {
        let documentState = documentShowingFirstObject()
        let paneID = documentState.editorArea.focusedPaneID
        documentState.selectionRouter.trigger(.open(secondObject, in: .newTab))
        #expect(documentState.editorArea.canClosePane(paneID))
        var routes: [SelectionRoute] = []
        let subscription = documentState.routeSignal.emitOnNext { routes.append($0) }
        defer { subscription.dispose() }

        documentState.selectionRouter.trigger(.closeEditorPane(paneID))

        let editorArea = documentState.editorArea
        #expect(editorArea.layout.paneIDs == [paneID])
        #expect(editorArea.focusedPaneID == paneID)
        #expect(editorArea.focusedPane.tabs.count == 1)
        #expect(editorArea.hasShownNothing)
        #expect(documentState.selectedRuntimeObject == nil)
        #expect(routes.count == 1)
        #expect(!editorArea.canClosePane(paneID), "an empty only pane has nothing left to close")
    }

    @Test("closing the only pane while it shows nothing changes nothing, and the route is not sent")
    func closingTheEmptyOnlyPaneChangesNothing() {
        let documentState = DocumentState()
        let editorAreaBefore = documentState.editorArea
        var routes: [SelectionRoute] = []
        let subscription = documentState.routeSignal.emitOnNext { routes.append($0) }
        defer { subscription.dispose() }

        documentState.selectionRouter.trigger(.closeEditorPane(documentState.editorArea.focusedPaneID))

        #expect(documentState.editorArea == editorAreaBefore)
        #expect(routes.isEmpty)
    }

    @Test("⌘W closes the focused tab while its pane has another")
    func closeTargetIsTheTab() {
        let documentState = documentShowingFirstObject()
        documentState.selectionRouter.trigger(.newEditorPane(.onRight))
        documentState.selectionRouter.trigger(.newTab)

        #expect(documentState.editorArea.closeTarget == .tab(documentState.editorArea.focusedPane.activeTabID))
    }

    @Test("⌘W closes the focused pane when its tab is its last and there is another pane")
    func closeTargetIsThePane() {
        let documentState = documentShowingFirstObject()
        documentState.selectionRouter.trigger(.newEditorPane(.onRight))

        #expect(documentState.editorArea.closeTarget == .pane(documentState.editorArea.focusedPaneID))
    }

    @Test("⌘W closes the window on the only tab of the only pane")
    func closeTargetIsTheWindow() {
        let documentState = documentShowingFirstObject()

        #expect(documentState.editorArea.closeTarget == .window)
    }

    // MARK: - Histories and focus

    @Test("each tab walks only the history it has made")
    func historiesBelongToTheirTabs() {
        let documentState = documentShowingFirstObject()
        documentState.selectionRouter.trigger(.open(secondObject, in: .focusedTab))
        let firstTabID = documentState.editorArea.focusedPane.activeTabID
        documentState.selectionRouter.trigger(.open(thirdObject, in: .newTab))

        documentState.selectionRouter.trigger(.backward)
        #expect(documentState.selectedRuntimeObject == thirdObject, "the new tab has nothing to go back to")

        documentState.selectionRouter.trigger(.switchTab(firstTabID))
        documentState.selectionRouter.trigger(.backward)
        #expect(documentState.selectedRuntimeObject == firstObject)
    }

    @Test("focusing another pane makes its object and its insertion point the document's")
    func focusCarriesTheSelectionAndTheInsertionPoint() {
        let documentState = documentShowingFirstObject()
        let firstPaneID = documentState.editorArea.focusedPaneID
        let firstMember = RuntimeMemberReference(object: firstObject, name: "first", kind: .objcMethod, isStatic: false)
        documentState.updateCursorMember(firstMember, inEditorPane: firstPaneID)
        documentState.selectionRouter.trigger(.open(secondObject, in: .nextEditorPane))
        #expect(documentState.selectedRuntimeObject == secondObject)
        #expect(documentState.cursorMember == nil)

        documentState.selectionRouter.trigger(.focusEditorPane(firstPaneID))

        #expect(documentState.selectedRuntimeObject == firstObject)
        #expect(documentState.cursorMember == firstMember)
    }

    @Test("an insertion point reported by a pane without the focus does not become the document's")
    func backgroundInsertionPointsStayTheirPanes() {
        let documentState = documentShowingFirstObject()
        let firstPaneID = documentState.editorArea.focusedPaneID
        documentState.selectionRouter.trigger(.newEditorPane(.onRight))

        documentState.updateCursorMember(RuntimeMemberReference(object: firstObject, name: "first", kind: .objcMethod, isStatic: false), inEditorPane: firstPaneID)

        #expect(documentState.cursorMember == nil)
    }

    @Test("clicking a tab of another pane focuses that pane")
    func switchingToATabFocusesItsPane() {
        let documentState = documentShowingFirstObject()
        let firstPaneID = documentState.editorArea.focusedPaneID
        let firstPaneTabID = documentState.editorArea.focusedPane.activeTabID
        documentState.selectionRouter.trigger(.open(secondObject, in: .nextEditorPane))

        documentState.selectionRouter.trigger(.switchTab(firstPaneTabID))

        #expect(documentState.editorArea.focusedPaneID == firstPaneID)
        #expect(documentState.selectedRuntimeObject == firstObject)
    }

    @Test("a route that changes nothing is not sent")
    func noOpRoutesAreNotSent() {
        let documentState = documentShowingFirstObject()
        var routes: [SelectionRoute] = []
        let subscription = documentState.routeSignal.emitOnNext { routes.append($0) }
        defer { subscription.dispose() }

        documentState.selectionRouter.trigger(.backward)
        documentState.selectionRouter.trigger(.forward)
        documentState.selectionRouter.trigger(.focusEditorPane(documentState.editorArea.focusedPaneID))
        documentState.selectionRouter.trigger(.switchTab(documentState.editorArea.focusedPane.activeTabID))

        #expect(routes.isEmpty)
    }

    // MARK: - Images and engines

    @Test("switching the image keeps every pane, tab and history")
    func switchingTheImageKeepsTheEditorArea() throws {
        let imageTree = Fixtures.imageTree(rootName: "Others", imagePaths: [Fixtures.sampleImagePath])
        let documentState = documentShowingFirstObject()
        documentState.selectionRouter.trigger(.open(secondObject, in: .newTab))
        let editorAreaBefore = documentState.editorArea

        documentState.selectionRouter.trigger(.switchImage(try #require(imageTree.leaf(forImagePath: Fixtures.sampleImagePath))))
        documentState.selectionRouter.trigger(.switchImage(nil))

        #expect(documentState.editorArea == editorAreaBefore)
        #expect(documentState.selectedRuntimeObject == secondObject)
    }

    @Test("opening an image records it after the object on screen, and neither the sidebar nor the object follows")
    func openingAnImage() {
        let documentState = documentShowingFirstObject()

        documentState.selectionRouter.trigger(.openImage(Fixtures.sampleImagePath, in: .focusedTab))

        let activeTab = documentState.editorArea.focusedPane.activeTab
        #expect(activeTab.history.entries == [NavigationEntry(object: firstObject), NavigationEntry(imagePath: Fixtures.sampleImagePath)])
        #expect(activeTab.imagePath == Fixtures.sampleImagePath)
        #expect(activeTab.object == nil)
        #expect(activeTab.title == "Sample")
        #expect(documentState.selectedRuntimeObject == nil, "an image is no object, so the Inspector has nothing to show")
        #expect(documentState.currentImageNode == nil, "the sidebar stays where it was")
    }

    @Test("going back from an image shows the object before it again")
    func goingBackFromAnImage() {
        let documentState = documentShowingFirstObject()
        documentState.selectionRouter.trigger(.openImage(Fixtures.sampleImagePath, in: .focusedTab))

        documentState.selectionRouter.trigger(.backward)

        #expect(documentState.selectedRuntimeObject == firstObject)
        documentState.selectionRouter.trigger(.forward)
        #expect(documentState.editorArea.focusedPane.activeTab.imagePath == Fixtures.sampleImagePath)
    }

    @Test("opening the image on screen again is no new step")
    func openingTheSameImageTwice() {
        let documentState = documentShowingFirstObject()
        documentState.selectionRouter.trigger(.openImage(Fixtures.sampleImagePath, in: .focusedTab))

        documentState.selectionRouter.trigger(.openImage(Fixtures.sampleImagePath, in: .focusedTab))

        #expect(documentState.editorArea.focusedPane.activeTab.history.entries.count == 2)
    }

    @Test("an image opens in a new tab and in the next pane like an object")
    func openingAnImageElsewhere() {
        let documentState = documentShowingFirstObject()
        let firstPaneID = documentState.editorArea.focusedPaneID

        documentState.selectionRouter.trigger(.openImage(Fixtures.sampleImagePath, in: .newTab))
        #expect(documentState.editorArea.focusedPane.tabs.count == 2)
        #expect(documentState.editorArea.focusedPane.activeTab.history.entries == [NavigationEntry(imagePath: Fixtures.sampleImagePath)])

        documentState.selectionRouter.trigger(.openImage(Fixtures.sampleImagePath, in: .nextEditorPane))
        #expect(documentState.editorArea.layout.paneIDs.count == 2)
        #expect(documentState.editorArea.focusedPaneID != firstPaneID)
        #expect(documentState.editorArea.focusedPane.activeTab.imagePath == Fixtures.sampleImagePath)
    }

    @Test("a tab showing an image shows the image's name and the icon of what it is part of")
    func tabBarItemOfAnImage() {
        let documentState = documentShowingFirstObject()
        documentState.selectionRouter.trigger(.openImage(Fixtures.sampleImagePath, in: .newTab))

        let snapshot = TabBarSnapshot(pane: documentState.editorArea.focusedPane)

        #expect(snapshot.items.map(\.title) == ["First", "Sample"])
        // `Fixtures.sampleImagePath` is in Sample.framework.
        #expect(snapshot.items.map(\.icon) == [.object(firstObject.kind), .image(.framework)])
    }

    @Test("switching the engine starts over with one pane holding one empty tab")
    func switchingTheEngineStartsOver() {
        let documentState = documentShowingFirstObject()
        documentState.selectionRouter.trigger(.newEditorPane(.onRight))
        documentState.selectionRouter.trigger(.newTab)

        documentState.selectionRouter.trigger(.switchEngine(RuntimeEngine(source: .local, engineID: "EditorAreaRoutingTests.otherEngine")))

        #expect(documentState.editorArea.layout.paneIDs.count == 1)
        #expect(documentState.editorArea.focusedPane.tabs.count == 1)
        #expect(documentState.selectedRuntimeObject == nil)
    }

    // MARK: - Invariants

    @Test("an editor area whose focused pane is gone stops the process")
    func aMissingFocusedPaneStops() async {
        await #expect(processExitsWith: .failure) {
            var editorArea = EditorArea()
            editorArea.panes = [:]
            _ = editorArea.focusedPane
        }
    }
}
