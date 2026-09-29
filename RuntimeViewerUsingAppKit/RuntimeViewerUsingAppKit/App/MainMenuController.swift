import AppKit
import DependenciesMacros
import RuntimeViewerArchitectures
import SFSymbols
import UIFoundation

@MainActor
final class MainMenuController {
    fileprivate static let shared = MainMenuController()

    private init() {}

    func makeMainMenu() -> NSMenu {
        MainMenu.menu {
            applicationMenuItem()
            fileMenuItem()
            editMenuItem()
            viewMenuItem()
            navigateMenuItem()
            MainMenu.window()
            MainMenu.help()
        }
    }

    // MARK: - Application

    private func applicationMenuItem() -> NSMenuItem {
        MainMenu.application { builder in
            builder.item(for: .Application.settings)?.action = #selector(AppDelegate.showSettings(_:))
            builder.insertItems(after: .Application.settings) {
                simulatorAppInstallerItem()
            }
        }
    }

    private func simulatorAppInstallerItem() -> NSMenuItem {
        NSMenuItem(
            "Simulator App Installer…",
            action: #selector(AppDelegate.showSimulatorInstaller(_:)),
            keyEquivalent: "I",
        )
        .image(SFSymbols(systemName: .iphoneAndArrowForwardInward).nsImage)
    }

    // MARK: - File

    private func fileMenuItem() -> NSMenuItem {
        MainMenu.file { builder in
            builder.insertItems(after: .File.open) {
                openQuicklyItem()
            }
            builder.insertItems(after: .File.close) {
                exportItem()
                exportMultipleImagesItem()
            }
            builder.remove(.File.save)
            builder.remove(.File.saveAs)
            builder.remove(.File.revertToSaved)
        }
    }

    private func openQuicklyItem() -> NSMenuItem {
        NSMenuItem(
            "Open Quickly…",
            action: #selector(SidebarRuntimeObjectListViewController.openQuickly(_:)),
            keyEquivalent: "O",
        )
        .image(SFSymbols(systemName: .bolt).nsImage)
    }

    private func exportItem() -> NSMenuItem {
        NSMenuItem(
            "Export",
            action: #selector(MainWindowController.exportInterface(_:)),
            keyEquivalent: "e",
        )
        .image(SFSymbols(systemName: .squareAndArrowUp).nsImage)
    }

    private func exportMultipleImagesItem() -> NSMenuItem {
        NSMenuItem(
            "Export Multiple Images…",
            action: #selector(MainWindowController.exportMultipleImages(_:)),
            keyEquivalent: "E",
            modifiers: [.shift, .command],
        )
        .image(SFSymbols(systemName: .squareAndArrowUpOnSquare).nsImage)
    }

    // MARK: - Edit
    
    private func editMenuItem() -> NSMenuItem {
        MainMenu.edit { builder in
            builder.item(for: .Edit.Find.find)?.action = #selector(NSResponder.performTextFinderAction(_:))
            builder.insertItems(after: .Edit.Find.find) {
                findInIndexedImagesItem()
            }
        }
    }

    /// Xcode's Find in Workspace, shortcut included; the Find navigator searches every indexed
    /// image of the document's engine.
    private func findInIndexedImagesItem() -> NSMenuItem {
        NSMenuItem(
            "Find in Indexed Images…",
            action: #selector(MainWindowController.showFindNavigator(_:)),
            keyEquivalent: "F",
            modifiers: [.shift, .command],
        )
        .image(SFSymbols(systemName: .magnifyingglass).nsImage)
    }

    // MARK: - View

    /// The standard items, then the font-size commands. These change `Settings.theme.fontSize`,
    /// which every document shares, but they are only enabled while a document window is key.
    private func viewMenuItem() -> NSMenuItem {
        MainMenu.view { builder in
            builder.insertItems(after: .View.enterFullScreen) {
                NSMenuItem.separator()
                increaseFontSizeItem()
                decreaseFontSizeItem()
                resetFontSizeItem()
            }
        }
    }

    /// `+` is shifted on most layouts, so this is ⇧⌘= to press — the same key as Format › Font › Bigger.
    private func increaseFontSizeItem() -> NSMenuItem {
        NSMenuItem(
            "Increase Font Size",
            action: #selector(MainWindowController.increaseFontSize(_:)),
            keyEquivalent: "+",
        )
        .image(SFSymbols(systemName: .textformatSizeLarger).nsImage)
    }

    private func decreaseFontSizeItem() -> NSMenuItem {
        NSMenuItem(
            "Decrease Font Size",
            action: #selector(MainWindowController.decreaseFontSize(_:)),
            keyEquivalent: "-",
        )
        .image(SFSymbols(systemName: .textformatSizeSmaller).nsImage)
    }

    private func resetFontSizeItem() -> NSMenuItem {
        NSMenuItem(
            "Reset Font Size",
            action: #selector(MainWindowController.resetFontSize(_:)),
            keyEquivalent: "0",
        )
        .image(SFSymbols(systemName: .textformatSize).nsImage)
    }

    // MARK: - Navigate

    /// Between View and Window, where Xcode keeps its own Navigate menu.
    private func navigateMenuItem() -> NSMenuItem {
        NSMenuItem("Navigate") {
            revealInSidebarNavigatorItem()
        }
    }

    /// Xcode's Reveal in Project Navigator, shortcut included.
    private func revealInSidebarNavigatorItem() -> NSMenuItem {
        NSMenuItem(
            "Reveal in Sidebar Navigator",
            action: #selector(MainWindowController.revealInSidebarNavigator(_:)),
            keyEquivalent: "J",
            modifiers: [.shift, .command],
        )
        .image(SFSymbols(systemName: .sidebarLeft).nsImage)
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { MainMenuController.shared })
    var mainMenuController: MainMenuController
}
