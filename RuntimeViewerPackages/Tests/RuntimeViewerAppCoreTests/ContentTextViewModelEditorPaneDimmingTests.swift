import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettings
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// Which editor pane draws its interface dimmed (proposal `dim-unfocused-editor-panes`): every pane but
/// the focused one, once the editor area has more than one, while Settings › Theme's Dim Unfocused
/// Editor Panes is on — as Xcode 27.2 dims the panes that are not the last active one.
@Suite("ContentTextViewModel editor pane dimming")
@MainActor
struct ContentTextViewModelEditorPaneDimmingTests {
    private static let runtimeObject = Fixtures.runtimeObject(name: "DimmingFixture", kind: .objc(.type(.class)), imagePath: TestImages.libobjc)

    @Test("the only pane is never dimmed")
    func aSinglePaneIsNeverDimmed() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(inPane: environment.documentState.editorArea.focusedPaneID, of: environment)
        defer { withExtendedLifetime(viewModel) {} }

        #expect(try await nextValue(from: output.isEditorPaneDimmed) == false)
    }

    @Test("a pane is dimmed while another pane has the focus")
    func aPaneIsDimmedWhileAnotherPaneHasTheFocus() async throws {
        let environment = ViewModelTestEnvironment()
        let firstPaneID = environment.documentState.editorArea.focusedPaneID
        let (viewModel, output) = makeViewModel(inPane: firstPaneID, of: environment)
        defer { withExtendedLifetime(viewModel) {} }

        environment.documentState.selectionRouter.trigger(.newEditorPane(.onRight))
        try #require(environment.documentState.editorArea.focusedPaneID != firstPaneID, "a new pane takes the focus")

        #expect(try await nextValue(from: output.isEditorPaneDimmed) { $0 } == true)
    }

    @Test("a dimmed pane is drawn normally again once it takes the focus back")
    func focusingThePaneUndimsIt() async throws {
        let environment = ViewModelTestEnvironment()
        let firstPaneID = environment.documentState.editorArea.focusedPaneID
        let (viewModel, output) = makeViewModel(inPane: firstPaneID, of: environment)
        defer { withExtendedLifetime(viewModel) {} }
        environment.documentState.selectionRouter.trigger(.newEditorPane(.onRight))
        _ = try await nextValue(from: output.isEditorPaneDimmed) { $0 }

        environment.documentState.selectionRouter.trigger(.focusEditorPane(firstPaneID))

        #expect(try await nextValue(from: output.isEditorPaneDimmed) { !$0 } == false)
    }

    @Test("the focused pane of several is not dimmed")
    func theFocusedPaneOfSeveralIsNotDimmed() async throws {
        let environment = ViewModelTestEnvironment()
        environment.documentState.selectionRouter.trigger(.newEditorPane(.onRight))
        let (viewModel, output) = makeViewModel(inPane: environment.documentState.editorArea.focusedPaneID, of: environment)
        defer { withExtendedLifetime(viewModel) {} }
        try #require(environment.documentState.editorArea.panes.count == 2)

        #expect(try await nextValue(from: output.isEditorPaneDimmed) == false)
    }

    @Test("turning Dim Unfocused Editor Panes off draws every pane normally")
    func turningTheSettingOffUndimsEveryPane() async throws {
        let environment = ViewModelTestEnvironment()
        let firstPaneID = environment.documentState.editorArea.focusedPaneID
        let (viewModel, output) = makeViewModel(inPane: firstPaneID, of: environment)
        defer { withExtendedLifetime(viewModel) {} }
        environment.documentState.selectionRouter.trigger(.newEditorPane(.onRight))
        _ = try await nextValue(from: output.isEditorPaneDimmed) { $0 }

        environment.settings.theme.dimsUnfocusedEditorPanes = false

        #expect(try await nextValue(from: output.isEditorPaneDimmed) { !$0 } == false)
    }

    private func makeViewModel(
        inPane editorPaneID: EditorPane.ID,
        of environment: ViewModelTestEnvironment
    ) -> (ContentTextViewModel, ContentTextViewModel.Output) {
        let viewModel = environment.make {
            ContentTextViewModel(
                runtimeObject: Self.runtimeObject,
                editorPaneID: editorPaneID,
                documentState: environment.documentState,
                router: MockRouter<ContentRoute>(),
                interfaceProvider: { runtimeObject, _ in
                    RuntimeObjectInterface(object: runtimeObject, interfaceString: "@interface DimmingFixture @end")
                }
            )
        }
        let output = viewModel.transform(.init(runtimeObjectClicked: .empty(), runtimeObjectOpenedInNewTab: .empty(), interfaceDisplayed: .empty()))
        return (viewModel, output)
    }
}
