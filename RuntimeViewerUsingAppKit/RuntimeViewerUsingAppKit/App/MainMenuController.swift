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
            MainMenu.view()
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
        }
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { MainMenuController.shared })
    var mainMenuController: MainMenuController
}
