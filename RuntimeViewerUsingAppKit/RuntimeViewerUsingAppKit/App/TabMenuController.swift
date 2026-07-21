import AppKit
import RuntimeViewerArchitectures
import DependenciesMacros

/// Installs the content-pane tab menu items into the standard File menu.
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

        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(MainWindowController.closeTab(_:)), keyEquivalent: "w")
        closeTabItem.keyEquivalentModifierMask = [.command]
        self.closeTabItem = closeTabItem

        fileMenu.insertItem(newTabItem, at: insertionIndex)
        fileMenu.insertItem(closeTabItem, at: insertionIndex + 1)

        fileMenu.delegate = self

        installTabNavigationItems()
    }

    private func installTabNavigationItems() {
        guard let windowMenu = NSApp.windowsMenu else { return }

        let showNextTabItem = NSMenuItem(title: "Show Next Tab", action: #selector(MainWindowController.selectNextTab(_:)), keyEquivalent: "]")
        showNextTabItem.keyEquivalentModifierMask = [.command, .shift]

        let showPreviousTabItem = NSMenuItem(title: "Show Previous Tab", action: #selector(MainWindowController.selectPreviousTab(_:)), keyEquivalent: "[")
        showPreviousTabItem.keyEquivalentModifierMask = [.command, .shift]

        windowMenu.addItem(.separator())
        windowMenu.addItem(showNextTabItem)
        windowMenu.addItem(showPreviousTabItem)
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
    /// Re-keys ⌘W per key window, Safari-style. AppKit fully updates a menu
    /// through this delegate method before matching key equivalents, so the
    /// re-keying applies to both the visible menu and the shortcut path.
    ///
    /// - Document window key (its responder chain answers `closeTab(_:)`):
    ///   Close Tab = ⌘W, Close Window = ⌘⇧W.
    /// - Any other window (Settings, About, panels): Close Tab loses its key
    ///   equivalent (the item is disabled anyway) and Close Window takes ⌘W
    ///   back, so ⌘W still closes those windows instead of beeping.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let keyWindowHandlesTabs = NSApp.target(forAction: #selector(MainWindowController.closeTab(_:))) != nil
        if keyWindowHandlesTabs {
            closeTabItem?.keyEquivalent = "w"
            closeTabItem?.keyEquivalentModifierMask = [.command]
            closeWindowItem?.keyEquivalent = "w"
            closeWindowItem?.keyEquivalentModifierMask = [.command, .shift]
        } else {
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
