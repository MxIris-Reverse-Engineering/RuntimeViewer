import AppKit
import RuntimeViewerArchitectures
import DependenciesMacros

/// Installs the tab and editor pane items into the standard File menu. Show Next / Previous Tab are
/// in the Navigate menu, where Xcode has them (`MainMenuController`).
///
/// Actions target `nil` so they travel the responder chain to the key
/// document window's `MainWindowController`, which owns the `DocumentState`
/// the tab routes mutate. Following the `AppDelegate` convention, `AppDelegate`
/// only calls `install()`.
@MainActor
final class TabMenuController: NSObject {
    fileprivate static let shared = TabMenuController()

    /// Kept for `menuNeedsUpdate` re-keying (see `NSMenuDelegate` below).
    private var closeWindowItem: NSMenuItem?
    private var closeTabItem: NSMenuItem?

    private override init() { super.init() }

    func install() {
        guard let fileMenu = fileMenu() else { return }

        // Re-key the standard "Close" (window) item to ⌘⇧W so ⌘W can close the
        // active tab instead (Safari behaviour). `menuNeedsUpdate` re-keys
        // both items dynamically per key window — for non-document windows
        // (Settings, About) ⌘W falls back to closing the window.
        let closeWindowItem = fileMenu.items.first { $0.action == #selector(NSWindow.performClose(_:)) }
        if let closeWindowItem {
            closeWindowItem.title = "Close Window"
            closeWindowItem.keyEquivalent = "w"
            closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
        }
        self.closeWindowItem = closeWindowItem

        let insertionIndex = closeWindowItem.flatMap { fileMenu.index(of: $0) } ?? 0

        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(MainWindowController.newTab(_:)), keyEquivalent: "t")
        newTabItem.keyEquivalentModifierMask = [.command]

        // Xcode's File ▸ New ▸ Editor Pane On Right / Below, shortcuts included. This File menu has
        // no New submenu, so they stand beside New Tab with "New" in front.
        let newEditorPaneOnRightItem = NSMenuItem(title: "New Editor Pane On Right", action: #selector(MainWindowController.newEditorPaneOnRight(_:)), keyEquivalent: "t")
        newEditorPaneOnRightItem.keyEquivalentModifierMask = [.control, .command]
        newEditorPaneOnRightItem.image = NSImage(systemSymbolName: "inset.filled.righthalf.rectangle", accessibilityDescription: nil)

        let newEditorPaneBelowItem = NSMenuItem(title: "New Editor Pane Below", action: #selector(MainWindowController.newEditorPaneBelow(_:)), keyEquivalent: "t")
        newEditorPaneBelowItem.keyEquivalentModifierMask = [.control, .option, .command]
        newEditorPaneBelowItem.image = NSImage(systemSymbolName: "inset.filled.bottomhalf.rectangle", accessibilityDescription: nil)

        // Closes the tab, else the editor pane, else the window: the order of Xcode's ⌘W.
        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(MainWindowController.closeTab(_:)), keyEquivalent: "w")
        closeTabItem.keyEquivalentModifierMask = [.command]
        self.closeTabItem = closeTabItem

        let closeEditorPaneItem = NSMenuItem(title: "Close Editor Pane", action: #selector(MainWindowController.closeEditorPane(_:)), keyEquivalent: "w")
        closeEditorPaneItem.keyEquivalentModifierMask = [.control, .shift, .command]

        let closeOtherEditorPanesItem = NSMenuItem(title: "Close Other Editor Panes", action: #selector(MainWindowController.closeOtherEditorPanes(_:)), keyEquivalent: "w")
        closeOtherEditorPanesItem.keyEquivalentModifierMask = [.control, .option, .shift, .command]
        closeOtherEditorPanesItem.image = NSImage(systemSymbolName: "rectangle.on.rectangle.slash", accessibilityDescription: nil)

        let items = [newTabItem, newEditorPaneOnRightItem, newEditorPaneBelowItem, closeTabItem, closeEditorPaneItem, closeOtherEditorPanesItem]
        for (offset, item) in items.enumerated() {
            fileMenu.insertItem(item, at: insertionIndex + offset)
        }

        fileMenu.delegate = self
    }

    /// The submenu of the standard "File" menu, located by its `performClose:`
    /// item rather than by title (so it survives localization).
    private func fileMenu() -> NSMenu? {
        NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .first { menu in menu.items.contains { $0.action == #selector(NSWindow.performClose(_:)) } }
    }
}

// MARK: - NSMenuDelegate

extension TabMenuController: NSMenuDelegate {
    /// Re-keys and retitles ⌘W per key window. AppKit fully updates a menu
    /// through this delegate method before matching key equivalents, so the
    /// re-keying applies to both the visible menu and the shortcut path.
    ///
    /// - Document window key (its responder chain answers `closeTab(_:)`) with
    ///   a tab or an editor pane to close: the ⌘W item is titled for it, as
    ///   Xcode titles its own — Close Tab or Close Editor Pane — and Close
    ///   Window = ⌘⇧W.
    /// - Document window key with nothing but the window to close: the ⌘W item
    ///   hides, and Close Window takes ⌘W, where Xcode titles its item Close
    ///   Window — two items of that title would differ only in their keys.
    /// - Any other window (Settings, About, panels): Close Tab loses its key
    ///   equivalent (the item is disabled anyway) and Close Window takes ⌘W
    ///   back, so ⌘W still closes those windows instead of beeping.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let windowController = NSApp.target(forAction: #selector(MainWindowController.closeTab(_:))) as? MainWindowController
        if let closeTabTitle = windowController?.closeTabMenuItemTitle {
            closeTabItem?.title = closeTabTitle
            closeTabItem?.isHidden = false
            closeTabItem?.keyEquivalent = "w"
            closeTabItem?.keyEquivalentModifierMask = [.command]
            closeWindowItem?.keyEquivalent = "w"
            closeWindowItem?.keyEquivalentModifierMask = [.command, .shift]
        } else {
            closeTabItem?.title = "Close Tab"
            closeTabItem?.isHidden = windowController != nil
            closeTabItem?.keyEquivalent = ""
            closeWindowItem?.keyEquivalent = "w"
            closeWindowItem?.keyEquivalentModifierMask = [.command]
        }
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { TabMenuController.shared })
    var tabMenuController: TabMenuController
}
