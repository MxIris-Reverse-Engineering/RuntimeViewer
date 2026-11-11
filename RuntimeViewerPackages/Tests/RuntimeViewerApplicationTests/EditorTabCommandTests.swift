import Foundation
import Testing
import RxSwift
import RuntimeViewerArchitectures
@testable import RuntimeViewerCore
@testable import RuntimeViewerApplication

/// An editor tab's context menu and the order a drag leaves the tabs in
/// (draft-context-menus).
@Suite("Editor tab commands")
@MainActor
struct EditorTabCommandTests {
    private let router = MockRouter<EditorAreaRoute>()
    private let tabCommandChosenRelay = PublishRelay<(command: EditorTabCommand, tabID: DocumentTab.ID)>()
    private let tabsReorderedRelay = PublishRelay<[DocumentTab.ID]>()

    private let nsObject = Fixtures.runtimeObject(name: "NSObject", kind: .objc(.type(.class)), imagePath: TestImages.libobjc)
    private let nsCopying = Fixtures.runtimeObject(name: "NSCopying", kind: .objc(.type(.protocol)), imagePath: TestImages.libobjc)
    private let nsString = Fixtures.runtimeObject(name: "NSString", kind: .objc(.type(.class)), imagePath: TestImages.foundation)

    @Test("a lone tab offers Close Tab and the commands on its object, less the two that act on the focused tab")
    func loneTabCommands() {
        let environment = ViewModelTestEnvironment()
        environment.documentState.selectionRouter.trigger(.open(nsObject, in: .focusedTab))
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let tabID = environment.documentState.editorArea.focusedPane.tabs[0].id

        #expect(viewModel.commands(forTab: tabID) == [
            .close,
            .runtimeObjectAction(.openInNextEditorPane),
            .runtimeObjectAction(.findTypeReferences),
            .runtimeObjectAction(.copyName),
        ])
    }

    @Test("the closing commands follow the tabs around the one clicked")
    func closingCommandsFollowTheNeighbours() {
        let environment = openThreeTabs()
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let tabIDs = environment.documentState.editorArea.focusedPane.tabs.map(\.id)

        #expect(viewModel.commands(forTab: tabIDs[0]).prefix(3) == [.close, .closeOthers, .closeToTheRight])
        #expect(viewModel.commands(forTab: tabIDs[2]).prefix(2) == [.close, .closeOthers])
        #expect(!viewModel.commands(forTab: tabIDs[2]).contains(.closeToTheRight))
    }

    @Test("Close Other Tabs leaves only the tab clicked")
    func closeOtherTabsLeavesTheClickedTab() async throws {
        let environment = openThreeTabs()
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let tabIDs = environment.documentState.editorArea.focusedPane.tabs.map(\.id)

        tabCommandChosenRelay.accept((.closeOthers, tabIDs[1]))

        let editorArea = try await nextValue(from: environment.documentState.$editorArea) { $0.focusedPane.tabs.count == 1 }
        #expect(editorArea.focusedPane.tabs.map(\.id) == [tabIDs[1]])
    }

    @Test("Close Tabs to the Right closes the tabs after the one clicked")
    func closeTabsToTheRightClosesTheLaterTabs() async throws {
        let environment = openThreeTabs()
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let tabIDs = environment.documentState.editorArea.focusedPane.tabs.map(\.id)

        tabCommandChosenRelay.accept((.closeToTheRight, tabIDs[0]))

        let editorArea = try await nextValue(from: environment.documentState.$editorArea) { $0.focusedPane.tabs.count == 1 }
        #expect(editorArea.focusedPane.tabs.map(\.id) == [tabIDs[0]])
    }

    @Test("a command on the object is carried out on the tab's own object")
    func objectCommandActsOnTheTabsObject() {
        let environment = openThreeTabs()
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let tabIDs = environment.documentState.editorArea.focusedPane.tabs.map(\.id)

        tabCommandChosenRelay.accept((.runtimeObjectAction(.copyName), tabIDs[1]))

        #expect(environment.pasteboard.copiedStrings == [nsCopying.displayName])
    }

    @Test("dragging a tab moves it in the pane")
    func draggingATabMovesIt() async throws {
        let environment = openThreeTabs()
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let tabIDs = environment.documentState.editorArea.focusedPane.tabs.map(\.id)

        tabsReorderedRelay.accept([tabIDs[2], tabIDs[0], tabIDs[1]])

        let editorArea = try await nextValue(from: environment.documentState.$editorArea) { $0.focusedPane.tabs.first?.id == tabIDs[2] }
        #expect(editorArea.focusedPane.tabs.map(\.id) == [tabIDs[2], tabIDs[0], tabIDs[1]])
    }

    @Test("the tab a drag moved is the one without which both orders agree")
    func movedTabIsTheOneWithoutWhichTheOrdersAgree() {
        let first = DocumentTab.ID()
        let second = DocumentTab.ID()
        let third = DocumentTab.ID()

        let movedToFront = EditorPaneViewModel.movedTab(from: [first, second, third], to: [third, first, second])
        #expect(movedToFront?.tabID == third)
        #expect(movedToFront?.destinationIndex == 0)

        let movedToBack = EditorPaneViewModel.movedTab(from: [first, second, third], to: [second, third, first])
        #expect(movedToBack?.tabID == first)
        #expect(movedToBack?.destinationIndex == 2)

        #expect(EditorPaneViewModel.movedTab(from: [first, second], to: [first, second]) == nil)
        #expect(EditorPaneViewModel.movedTab(from: [first, second], to: [first, third]) == nil)
    }

    // MARK: - Helpers

    /// NSObject, NSCopying and NSString, each in a tab of its own.
    private func openThreeTabs() -> ViewModelTestEnvironment {
        let environment = ViewModelTestEnvironment()
        environment.documentState.selectionRouter.trigger(.open(nsObject, in: .focusedTab))
        environment.documentState.selectionRouter.trigger(.open(nsCopying, in: .newTab))
        environment.documentState.selectionRouter.trigger(.open(nsString, in: .newTab))
        return environment
    }

    private func makeViewModel(in environment: ViewModelTestEnvironment) -> EditorPaneViewModel {
        let viewModel = environment.make {
            EditorPaneViewModel(paneID: environment.documentState.editorArea.focusedPaneID, documentState: environment.documentState, router: router)
        }
        _ = viewModel.transform(.init(
            tabSelected: .empty(),
            tabClosed: .empty(),
            closeButtonClicked: .empty(),
            backgroundClicked: .empty(),
            tabCommandChosen: tabCommandChosenRelay.asSignal(),
            tabsReordered: tabsReorderedRelay.asSignal()
        ))
        return viewModel
    }
}
