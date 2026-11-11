import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication

/// A contextual-menu item that carries the object it acts on, so the action can read the
/// target straight off `sender` instead of the pane having to remember what was clicked.
///
/// Shared by both content panes: the `NSTextView` one builds its menu from
/// `textView(_:menu:for:at:)`, the Xcode-backed one from `setupContextMenu(for:)`, and neither
/// has anywhere to stash per-click state between building the item and running its action.
final class RuntimeObjectMenuItem: NSMenuItem {
    let runtimeObject: RuntimeObject

    /// The command every list offers that the item stands for, when it is one of them; the
    /// pane's own commands (Jump to Definition and the opens it resolves first) leave it `nil`.
    let runtimeObjectAction: RuntimeObjectAction?

    init(title: String, image: NSImage?, runtimeObject: RuntimeObject, runtimeObjectAction: RuntimeObjectAction? = nil) {
        self.runtimeObject = runtimeObject
        self.runtimeObjectAction = runtimeObjectAction
        super.init(title: title, action: nil, keyEquivalent: "")
        if #available(macOS 26.0, *) {
            self.image = image
        }
    }

    convenience init(title: String, symbolName: SFSymbols.SystemSymbolName, runtimeObject: RuntimeObject) {
        self.init(title: title, image: SFSymbols(systemName: symbolName).nsuiImage, runtimeObject: runtimeObject)
    }

    /// The item for `runtimeObjectAction`, titled as in every other menu.
    convenience init(_ runtimeObjectAction: RuntimeObjectAction, runtimeObject: RuntimeObject) {
        self.init(title: runtimeObjectAction.menuTitle, image: runtimeObjectAction.menuImage, runtimeObject: runtimeObject, runtimeObjectAction: runtimeObjectAction)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension NSMenuItem {
    /// Navigate ▸ Reveal in Sidebar Navigator, sent up the responder chain to the window, which
    /// enables it as it does the main menu's: for the object on screen, in the sidebar's image.
    static func revealInSidebarNavigator() -> NSMenuItem {
        NSMenuItem(title: "Reveal in Sidebar Navigator", action: #selector(MainWindowController.revealInSidebarNavigator(_:)), keyEquivalent: "").then {
            if #available(macOS 26.0, *) {
                $0.image = SFSymbols(systemName: .sidebarLeft).nsImage
            }
        }
    }
}
