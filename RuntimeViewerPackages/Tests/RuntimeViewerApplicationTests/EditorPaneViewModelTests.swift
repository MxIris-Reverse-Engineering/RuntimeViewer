import Foundation
import Testing
import RxSwift
import RuntimeViewerArchitectures
@testable import RuntimeViewerCore
@testable import RuntimeViewerApplication

/// What one editor pane's view model shows (proposal `editor-panes`): its tab bar from the
/// second pane or the second tab on, whether it has the focus, and the button that closes it.
@Suite("EditorPaneViewModel")
@MainActor
struct EditorPaneViewModelTests {
    private let router = MockRouter<EditorAreaRoute>()
    private let tabSelectedRelay = PublishRelay<DocumentTab.ID>()
    private let tabClosedRelay = PublishRelay<DocumentTab.ID>()
    private let closeButtonClickedRelay = PublishRelay<Void>()
    private let backgroundClickedRelay = PublishRelay<Void>()
    private let jumpBarChoiceRelay = PublishRelay<EditorJumpBarChoice>()

    private func makeViewModel(
        for paneID: EditorPane.ID,
        in environment: ViewModelTestEnvironment
    ) -> (EditorPaneViewModel, EditorPaneViewModel.Output) {
        let viewModel = environment.make {
            EditorPaneViewModel(paneID: paneID, documentState: environment.documentState, router: router)
        }
        let output = viewModel.transform(.init(
            tabSelected: tabSelectedRelay.asSignal(),
            tabClosed: tabClosedRelay.asSignal(),
            closeButtonClicked: closeButtonClickedRelay.asSignal(),
            backgroundClicked: backgroundClickedRelay.asSignal(),
            jumpBarChoiceSelected: jumpBarChoiceRelay.asSignal()
        ))
        return (viewModel, output)
    }

    @Test("the only pane with one tab hides its tab bar and its close button")
    func theOnlyPaneShowsNoBar() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(for: environment.documentState.editorArea.focusedPaneID, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        #expect(try await nextValue(from: output.isTabBarHidden) == true)
        #expect(try await nextValue(from: output.isCloseButtonHidden) == true)
    }

    @Test("the only pane shows its tab bar from its second tab on")
    func theOnlyPaneShowsTheBarFromTheSecondTab() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(for: environment.documentState.editorArea.focusedPaneID, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        environment.documentState.selectionRouter.trigger(.newTab)

        #expect(try await nextValue(from: output.isTabBarHidden) == false)
        #expect(try await nextValue(from: output.tabBarSnapshot).items.count == 2)
    }

    @Test("with a second pane every pane shows its tab bar and close button, even over one tab")
    func aSecondPaneShowsEveryBar() async throws {
        let environment = ViewModelTestEnvironment()
        let firstPaneID = environment.documentState.editorArea.focusedPaneID
        let (viewModel, output) = makeViewModel(for: firstPaneID, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        environment.documentState.selectionRouter.trigger(.newEditorPane(.onRight))

        #expect(try await nextValue(from: output.isTabBarHidden) == false)
        #expect(try await nextValue(from: output.isCloseButtonHidden) == false)
        #expect(try await nextValue(from: output.isFocused) == false, "the new pane took the focus")
    }

    @Test("clicking a pane's background focuses it, and its close button closes it")
    func clicksFocusAndClose() async throws {
        let environment = ViewModelTestEnvironment()
        let firstPaneID = environment.documentState.editorArea.focusedPaneID
        let (viewModel, output) = makeViewModel(for: firstPaneID, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        environment.documentState.selectionRouter.trigger(.newEditorPane(.onRight))

        backgroundClickedRelay.accept(())
        #expect(environment.documentState.editorArea.focusedPaneID == firstPaneID)
        #expect(try await nextValue(from: output.isFocused) == true)

        closeButtonClickedRelay.accept(())
        #expect(environment.documentState.editorArea.layout.paneIDs.count == 1)
        #expect(environment.documentState.editorArea[firstPaneID] == nil)
    }

    @Test("selecting and closing tabs act on the tab named, in its pane")
    func tabClicksActOnTheirTab() async throws {
        let environment = ViewModelTestEnvironment()
        let paneID = environment.documentState.editorArea.focusedPaneID
        let firstTabID = environment.documentState.editorArea.focusedPane.activeTabID
        let (viewModel, _) = makeViewModel(for: paneID, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        environment.documentState.selectionRouter.trigger(.newTab)
        let secondTabID = environment.documentState.editorArea.focusedPane.activeTabID

        tabSelectedRelay.accept(firstTabID)
        #expect(environment.documentState.editorArea.focusedPane.activeTabID == firstTabID)

        tabClosedRelay.accept(secondTabID)
        #expect(environment.documentState.editorArea.focusedPane.tabs.map(\.id) == [firstTabID])
    }

    // MARK: - Jump bar

    @Test("the jump bar points at what the pane's active tab shows")
    func jumpBarFollowsTheActiveTab() async throws {
        let environment = ViewModelTestEnvironment()
        let paneID = environment.documentState.editorArea.focusedPaneID
        let (viewModel, output) = makeViewModel(for: paneID, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let object = Fixtures.runtimeObject(name: "Shown")

        #expect(try await nextValue(from: output.jumpBarLocation) == .nothing)

        environment.documentState.selectionRouter.trigger(.open(object, in: .focusedTab))
        #expect(try await nextValue(from: output.jumpBarLocation) == .object(object))

        environment.documentState.selectionRouter.trigger(.openImage(Fixtures.sampleImagePath, in: .focusedTab))
        #expect(try await nextValue(from: output.jumpBarLocation) == .image(path: Fixtures.sampleImagePath))
    }

    @Test("a choice in the jump bar of a pane without the focus focuses that pane and opens there")
    func jumpBarChoiceOpensInItsPane() async throws {
        let environment = ViewModelTestEnvironment()
        let firstPaneID = environment.documentState.editorArea.focusedPaneID
        let (viewModel, _) = makeViewModel(for: firstPaneID, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        environment.documentState.selectionRouter.trigger(.newEditorPane(.onRight))
        #expect(environment.documentState.editorArea.focusedPaneID != firstPaneID)
        let object = Fixtures.runtimeObject(name: "Chosen")

        jumpBarChoiceRelay.accept(EditorJumpBarChoice(target: .image(path: Fixtures.sampleImagePath), destination: .focusedTab))
        #expect(environment.documentState.editorArea.focusedPaneID == firstPaneID)
        #expect(environment.documentState.editorArea[firstPaneID]?.activeTab.imagePath == Fixtures.sampleImagePath)
        #expect(environment.documentState.currentImageNode == nil, "the sidebar stays where it was")

        jumpBarChoiceRelay.accept(EditorJumpBarChoice(target: .object(object), destination: .newTab))
        #expect(environment.documentState.editorArea[firstPaneID]?.tabs.count == 2)
        #expect(environment.documentState.selectedRuntimeObject == object)
    }
}
