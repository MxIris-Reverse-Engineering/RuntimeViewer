import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication

/// The title and symbol of each runtime object command, the same in every
/// context menu that offers it.
extension RuntimeObjectAction {
    var menuTitle: String {
        switch self {
        case .openInNewTab: "Open in New Tab"
        case .openInNextEditorPane: "Open in Next Editor Pane"
        case .openGeneratedInterface: "Open Generated Interface"
        case .findTypeReferences: "Find Type References"
        case .copyName: "Copy Name"
        }
    }

    var menuImage: NSImage? {
        switch self {
        case .openInNewTab: SFSymbols(systemName: .plusSquareOnSquare).nsImage
        case .openInNextEditorPane: NSImage(systemSymbolName: "inset.filled.righthalf.rectangle", accessibilityDescription: nil)
        case .openGeneratedInterface: SFSymbols(systemName: .swift).nsImage
        case .findTypeReferences: SFSymbols(systemName: .magnifyingglass).nsImage
        case .copyName: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        }
    }
}
