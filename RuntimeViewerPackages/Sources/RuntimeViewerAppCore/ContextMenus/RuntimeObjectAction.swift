import Foundation
import RuntimeViewerCore

/// A command a context menu offers on a runtime object, wherever the object is
/// listed: a sidebar row, an Inspector row, a link in the content pane, an
/// editor tab.
///
/// One list, so that an object offers the same commands in every place, in
/// the same order and under the same titles (the app's
/// `RuntimeObjectAction+Menu`), and a command does the same thing wherever it
/// is chosen: `ViewModel.perform(_:on:)` carries every one of them out. A place
/// adds around these the commands only it has — a sidebar row's bookmark and
/// its jump to the other face, the content pane's Jump to Definition.
public enum RuntimeObjectAction: Hashable, Sendable {
    /// Opens the object in a new tab of the focused editor pane, as ⇧⌥-click
    /// does in a list.
    case openInNewTab

    /// Opens the object in the editor pane after the focused one, as ⌥-click
    /// does in a list.
    case openInNextEditorPane

    /// Opens an Objective-C object as Swift imports it, as one navigation step.
    case openGeneratedInterface

    /// Find Type References: the functions that reference the type.
    case findTypeReferences

    /// Puts the name the object is listed under on the pasteboard.
    case copyName

    /// The commands `object` offers, in menu order: the two ways of opening it,
    /// its Generated Interface when it has one, Find Type References when it is
    /// a type references are found for, and Copy Name.
    public static func actions(for object: RuntimeObject) -> [RuntimeObjectAction] {
        var actions: [RuntimeObjectAction] = [.openInNewTab, .openInNextEditorPane]
        if object.hasGeneratedInterface {
            actions.append(.openGeneratedInterface)
        }
        if typeReferencesRequest(for: object) != nil {
            actions.append(.findTypeReferences)
        }
        actions.append(.copyName)
        return actions
    }

    /// The command a click on a list row stands for when its modifiers send
    /// the row somewhere other than the focused tab — ⌥ Open in Next Editor Pane,
    /// ⇧⌥ Open in New Tab — so that a list offering the commands in its
    /// menu takes the clicks for them too; `nil` for a plain click, which each
    /// list handles its own way.
    public init?(opening destination: SelectionRoute.Destination) {
        switch destination {
        case .focusedTab: return nil
        case .newTab: self = .openInNewTab
        case .nextEditorPane: self = .openInNextEditorPane
        }
    }

    /// The Find Type References command for `object`, or `nil` when it is no
    /// type references are found for.
    static func typeReferencesRequest(for object: RuntimeObject) -> FindCrossReferenceRequest? {
        FindCrossReferenceRequest.requests(for: object).first { $0.mode == .typeReferences }
    }
}
