import AppKit
import RuntimeViewerCore
import RuntimeViewerUI

/// A contextual-menu item that carries the object it acts on, so the action can read the
/// target straight off `sender` instead of the pane having to remember what was clicked.
///
/// Shared by both content panes: the `NSTextView` one builds its menu from
/// `textView(_:menu:for:at:)`, the Xcode-backed one from `setupContextMenu(for:)`, and neither
/// has anywhere to stash per-click state between building the item and running its action.
final class RuntimeObjectMenuItem: NSMenuItem {
    let runtimeObject: RuntimeObject

    init(title: String, symbolName: SFSymbols.SystemSymbolName, runtimeObject: RuntimeObject) {
        self.runtimeObject = runtimeObject
        super.init(title: title, action: nil, keyEquivalent: "")
        if #available(macOS 26.0, *) {
            image = SFSymbols(systemName: symbolName).nsuiImgae
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
