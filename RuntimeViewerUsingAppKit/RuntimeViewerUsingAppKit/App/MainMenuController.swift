import AppKit
import DependenciesMacros
import RuntimeViewerArchitectures
import RuntimeViewerSourceEditorBridge
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
            // Every command in it is the SourceEditor content pane's, so a build that shows
            // interfaces in the built-in text view has no use for it.
            if SourceEditorBridgeFactory.isAvailable {
                editorMenuItem()
            }
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
                deleteDerivedDataItem()
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

    /// Asks before it deletes, so it has no key equivalent.
    private func deleteDerivedDataItem() -> NSMenuItem {
        NSMenuItem(
            "Delete Derived Data…",
            action: #selector(AppDelegate.deleteDerivedData(_:)),
            keyEquivalent: "",
        )
        .image(SFSymbols(systemName: .trash).nsImage)
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
                findCallHierarchyItem()
                findCalleesItem()
                findTypeReferencesItem()
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

    /// Xcode's Find Call Hierarchy, shortcut included (`Xcode.IDEKit.CmdDefinition.CallHierarchy`):
    /// the callers of the member at the content pane's insertion point.
    private func findCallHierarchyItem() -> NSMenuItem {
        NSMenuItem(
            "Find Call Hierarchy",
            action: #selector(MainWindowController.findCallHierarchy(_:)),
            keyEquivalent: "H",
            modifiers: [.control, .shift, .command],
        )
    }

    /// What the member at the insertion point calls. Xcode has no such command, so no shortcut.
    private func findCalleesItem() -> NSMenuItem {
        NSMenuItem(
            "Find Callees",
            action: #selector(MainWindowController.findCallees(_:)),
            keyEquivalent: "",
        )
    }

    /// The functions that reference the type on screen. Xcode has no such command either.
    private func findTypeReferencesItem() -> NSMenuItem {
        NSMenuItem(
            "Find Type References",
            action: #selector(MainWindowController.findTypeReferences(_:)),
            keyEquivalent: "",
        )
    }

    // MARK: - View

    /// The standard items, with the Report navigator next to the sidebar, then the font-size
    /// commands. These change `Settings.theme.fontSize`, which every document shares, but they are
    /// only enabled while a document window is key.
    private func viewMenuItem() -> NSMenuItem {
        MainMenu.view { builder in
            builder.insertItems(after: .View.showSidebar) {
                showReportNavigatorItem()
            }
            builder.insertItems(after: .View.enterFullScreen) {
                NSMenuItem.separator()
                changeEditorOrientationItem()
                resetEditorSizesItem()
                NSMenuItem.separator()
                increaseFontSizeItem()
                decreaseFontSizeItem()
                resetFontSizeItem()
            }
        }
    }

    /// Xcode's View ▸ Change Editor Orientation: the editor panes turn across, their arrangement
    /// kept. No shortcut in Xcode either.
    private func changeEditorOrientationItem() -> NSMenuItem {
        NSMenuItem(
            "Change Editor Orientation",
            action: #selector(MainWindowController.changeEditorOrientation(_:)),
        )
        .image(NSImage(systemSymbolName: "uiwindow.split.2x1", accessibilityDescription: nil))
    }

    /// Xcode's View ▸ Reset Editor Sizes.
    private func resetEditorSizesItem() -> NSMenuItem {
        NSMenuItem(
            "Reset Editor Sizes",
            action: #selector(MainWindowController.resetEditorSizes(_:)),
        )
        .image(NSImage(systemSymbolName: "square.resize", accessibilityDescription: nil))
    }

    /// Xcode's View ▸ Navigators ▸ Show Report Navigator, shortcut included.
    private func showReportNavigatorItem() -> NSMenuItem {
        NSMenuItem(
            "Show Report Navigator",
            action: #selector(MainWindowController.showReportNavigator(_:)),
            keyEquivalent: "9",
        )
        .image(SFSymbols.reportNavigator.nsImage)
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

    /// Between View and Window, where Xcode keeps its own Navigate menu, in Xcode's order: Reveal,
    /// moving the focus between editor panes, then stepping through the focused pane's tabs.
    private func navigateMenuItem() -> NSMenuItem {
        NSMenuItem("Navigate") {
            revealInSidebarNavigatorItem()
            NSMenuItem.separator()
            NSMenuItem(
                "Move Focus to Next Editor Pane",
                action: #selector(MainWindowController.moveFocusToNextEditorPane(_:)),
                keyEquivalent: "`",
                modifiers: [.control],
            )
            NSMenuItem(
                "Move Focus to Previous Editor Pane",
                action: #selector(MainWindowController.moveFocusToPreviousEditorPane(_:)),
                keyEquivalent: "`",
                modifiers: [.control, .shift],
            )
            NSMenuItem.separator()
            NSMenuItem(
                "Show Previous Tab",
                action: #selector(MainWindowController.selectPreviousTab(_:)),
                keyEquivalent: "[",
                modifiers: [.shift, .command],
            )
            NSMenuItem(
                "Show Next Tab",
                action: #selector(MainWindowController.selectNextTab(_:)),
                keyEquivalent: "]",
                modifiers: [.shift, .command],
            )
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

// MARK: - Editor

extension MainMenuController {
    /// After Navigate, where Xcode keeps its own Editor menu.
    private func editorMenuItem() -> NSMenuItem {
        NSMenuItem("Editor") {
            codeFoldingMenuItem()
        }
    }

    /// Xcode's Editor ▸ Code Folding, with its titles, symbols and shortcuts
    /// (`IDEPegasusSourceEditor.xcplugindata`, `MenuDefinition.CodeFolding`; the same in 26.6 and
    /// 27.2). The actions go up the responder chain to the SourceEditor content pane, which
    /// enables them, so they are greyed out wherever else the focus is. Fold and Unfold Methods &
    /// Functions are left out: they fold function bodies, and a generated interface has none.
    private func codeFoldingMenuItem() -> NSMenuItem {
        NSMenuItem("Code Folding") {
            NSMenuItem(
                "Fold",
                action: #selector(SourceEditorBridgingCodeFoldingCommands.fold(_:)),
                keyEquivalent: Self.leftArrowKeyEquivalent,
                modifiers: [.option, .command],
            )
            .image(SFSymbols(systemName: .rectangleCompressVertical).nsImage)
            NSMenuItem(
                "Unfold",
                action: #selector(SourceEditorBridgingCodeFoldingCommands.unfold(_:)),
                keyEquivalent: Self.rightArrowKeyEquivalent,
                modifiers: [.option, .command],
            )
            .image(SFSymbols(systemName: .rectangleExpandVertical).nsImage)
            NSMenuItem(
                "Unfold All",
                action: #selector(SourceEditorBridgingCodeFoldingCommands.unfoldAll(_:)),
            )
            .image(SFSymbols(systemName: .rectangleExpandVertical).nsImage)
            NSMenuItem.separator()
            NSMenuItem(
                "Fold Comment Blocks",
                action: #selector(SourceEditorBridgingCodeFoldingCommands.foldAllComments(_:)),
                keyEquivalent: Self.leftArrowKeyEquivalent,
                modifiers: [.control, .shift, .command],
            )
            .image(SFSymbols(systemName: .rectangleCompressVertical).nsImage)
            NSMenuItem(
                "Unfold Comment Blocks",
                action: #selector(SourceEditorBridgingCodeFoldingCommands.unfoldAllComments(_:)),
                keyEquivalent: Self.rightArrowKeyEquivalent,
                modifiers: [.control, .shift, .command],
            )
            .image(SFSymbols(systemName: .rectangleExpandVertical).nsImage)
        }
        .image(SFSymbols(systemName: .rectangleCompressVertical).nsImage)
    }

    private static let leftArrowKeyEquivalent = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))

    private static let rightArrowKeyEquivalent = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { MainMenuController.shared })
    var mainMenuController: MainMenuController
}
