import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

#if os(macOS)
extension ViewModel {
    /// Carries out `action` on `object`. Every context menu that offers a
    /// `RuntimeObjectAction` — the sidebar's, the Inspector's, the content
    /// pane's, an editor tab's — ends here, so a command does the same thing
    /// wherever it was chosen.
    public func perform(_ action: RuntimeObjectAction, on object: RuntimeObject) {
        switch action {
        case .openInNewTab:
            documentState.selectionRouter.trigger(.open(object, in: .newTab))
        case .openInNextEditorPane:
            documentState.selectionRouter.trigger(.open(object, in: .nextEditorPane))
        case .openGeneratedInterface:
            // Pushed like a click, so it enters the history; Back returns to
            // the header.
            guard object.hasGeneratedInterface else { return }
            documentState.selectionRouter.trigger(.open(object, in: .focusedTab, interfaceLanguage: .swift))
        case .findTypeReferences:
            guard let request = RuntimeObjectAction.typeReferencesRequest(for: object) else { return }
            documentState.findSession.runCrossReferenceCommand(request)
        case .copyName:
            pasteboardClient.copyString(object.displayName)
        }
    }
}
#endif
