import AppKit
import DependenciesMacros
import RuntimeViewerArchitectures
import SFSymbols
import UIFoundation

/// Assembles the application's main menu in code — the replacement for
/// `MainMenu.xib`.
///
/// The content mirrors what the xib shipped, item for item: built from
/// `UIFoundation`'s `MainMenu` factories where the item is Xcode's template
/// item, and written out where it is this app's own. Assembling through
/// `MainMenu.menu { … }` also performs the wiring Interface Builder's
/// `systemMenu` markers used to do — Services to `NSApplication.servicesMenu`,
/// Window to `windowsMenu`, Help to `helpMenu` — which is why the assembly has
/// to go through it rather than through a bare `NSMenu`.
///
/// Deliberately absent, because AppKit adds each of these itself once the menu
/// is installed and a hand-built copy would sit beside it as a duplicate:
///
/// - **File ▸ Open Recent.** `NSDocumentController` inserts and then owns a
///   submenu next to the `openDocument:` item, which is exactly where the
///   xib's sat. It adopts a xib's by a private menu name that has no public
///   counterpart, so a code-built one is invisible to it.
/// - **Window ▸** the open-window list and the tab items.
/// - **Help ▸** the help search field.
/// - **Edit ▸** Emoji & Symbols and Start Dictation…. AutoFill would be here
///   too; `SystemAutoFillMenuSuppression` is what keeps it away.
///
/// `TabMenuController` and `DebugMenuController` add their items after launch.
/// Both locate what they need by action or through `NSApp.windowsMenu`, never
/// by title or index, so neither depends on this menu's shape.
@MainActor
final class MainMenuController {
    fileprivate static let shared = MainMenuController()

    private init() {}

    /// The assembled main menu, ready for `NSApplication.mainMenu`.
    ///
    /// No item carries a target, so every action travels the responder chain.
    /// That is what the xib's "First Responder" connections did for all but two
    /// items: it pinned `showSettings:` and `showSimulatorInstaller:` to the
    /// `AppDelegate` object it instantiated. Nothing else in the chain answers
    /// those selectors and `NSApplication` offers its delegate last, so the two
    /// arrive at the same place either way.
    func makeMainMenu() -> NSMenu {
        MainMenu.menu {
            applicationMenuItem()
            fileMenuItem()
            editMenuItem()
            MainMenu.view()
            MainMenu.window()
            MainMenu.help()
        }
    }

    // MARK: - Application

    private func applicationMenuItem() -> NSMenuItem {
        MainMenu.application {
            MainMenu.Application.about()
            NSMenuItem.separator()
            // The factory titles this "Settings…" on macOS 13+, following the
            // system-wide rename. This app has always shown "Preferences…" and
            // keeps doing so.
            MainMenu.Application.settings(action: #selector(AppDelegate.showSettings(_:)))
                .title("Preferences…")
            simulatorAppInstallerItem()
            NSMenuItem.separator()
            MainMenu.Application.services()
            NSMenuItem.separator()
            MainMenu.Application.hide()
            MainMenu.Application.hideOthers()
            MainMenu.Application.showAll()
            NSMenuItem.separator()
            MainMenu.Application.quit()
        }
    }

    private func simulatorAppInstallerItem() -> NSMenuItem {
        NSMenuItem(
            "Simulator App Installer…",
            action: #selector(AppDelegate.showSimulatorInstaller(_:)),
            keyEquivalent: "I"
        )
        .image(SFSymbols(systemName: .iphoneAndArrowForwardInward).nsImage)
    }

    // MARK: - File

    private func fileMenuItem() -> NSMenuItem {
        MainMenu.file {
            MainMenu.File.new()
            MainMenu.File.open()
            // Open Recent belongs between these two — `NSDocumentController`
            // inserts it right after the `openDocument:` item above.
            openQuicklyItem()
            NSMenuItem.separator()
            MainMenu.File.close()
            exportItem()
            exportMultipleImagesItem()
        }
    }

    private func openQuicklyItem() -> NSMenuItem {
        NSMenuItem(
            "Open Quickly…",
            action: #selector(SidebarRuntimeObjectListViewController.openQuickly(_:)),
            keyEquivalent: "O"
        )
        .image(SFSymbols(systemName: .bolt).nsImage)
    }

    private func exportItem() -> NSMenuItem {
        NSMenuItem(
            "Export",
            action: #selector(MainWindowController.exportInterface(_:)),
            keyEquivalent: "e"
        )
        .image(SFSymbols(systemName: .squareAndArrowUp).nsImage)
    }

    private func exportMultipleImagesItem() -> NSMenuItem {
        NSMenuItem(
            "Export Multiple Images…",
            action: #selector(MainWindowController.exportMultipleImages(_:)),
            keyEquivalent: "E",
            modifiers: [.shift, .command]
        )
        .image(SFSymbols(systemName: .squareAndArrowUpOnSquare).nsImage)
    }

    // MARK: - Edit

    /// The template's Edit menu minus the four groups the xib dropped —
    /// Spelling and Grammar, Substitutions, Transformations, Speech — none of
    /// which apply to a read-only interface listing.
    private func editMenuItem() -> NSMenuItem {
        MainMenu.edit {
            MainMenu.Edit.undo()
            MainMenu.Edit.redo()
            NSMenuItem.separator()
            MainMenu.Edit.cut()
            MainMenu.Edit.copy()
            MainMenu.Edit.paste()
            MainMenu.Edit.pasteAndMatchStyle()
            MainMenu.Edit.delete()
            MainMenu.Edit.selectAll()
            NSMenuItem.separator()
            findMenuItem()
        }
    }

    /// The template's Find submenu with the one deviation the xib carried:
    /// Find… drives `NSTextFinder` through `performTextFinderAction:` instead
    /// of the template's `performFindPanelAction:`, that being the responder
    /// method `ContentTextViewController` implements. Its tag stays 1, which is
    /// `showFindInterface` in `NSTextFinder.Action` and `showFindPanel` in
    /// `NSFindPanelAction`, so the other five items are unaffected.
    ///
    /// Note that the factory's "Use Selection for Find" declares ⌘E and yet
    /// shows no shortcut at runtime: Export claims ⌘E first, and
    /// `setMainMenu(_:)` resolves the duplicate in favour of the earlier item.
    /// The xib declared the same collision and lost the same shortcut, so this
    /// is reproduced rather than worked around.
    private func findMenuItem() -> NSMenuItem {
        let findMenuItem = MainMenu.Edit.find()
        findMenuItem.submenu?
            .item(for: .Edit.Find.find)?
            .action = #selector(NSResponder.performTextFinderAction(_:))
        return findMenuItem
    }
}

// MARK: - Item Lookup

extension NSMenu {
    /// The receiver's own item carrying `identifier`, for the one place a
    /// standard item needs amending after its factory has built it.
    fileprivate func item(for identifier: MainMenu.ItemIdentifier) -> NSMenuItem? {
        items.first { $0.identifier == identifier.userInterfaceItemIdentifier }
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { MainMenuController.shared })
    var mainMenuController: MainMenuController
}
