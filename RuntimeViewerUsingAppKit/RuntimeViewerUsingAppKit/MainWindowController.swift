//
//  MainWindowController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures

class MainWindow: NSWindow {
    init() {
        super.init(contentRect: .init(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    }
}

class MainWindowController: XiblessWindowController<MainWindow> {
    let toolbarController = MainToolbarController()

    var viewModel: MainViewModel?
    
    func setupBindings(for viewModel: MainViewModel) {
        self.viewModel = viewModel
        let input = MainViewModel.Input(sidebarBackClick: toolbarController.backItem.backButton.rx.click.asSignal())
        let _ = viewModel.transform(input)
    }
    
    init() {
        super.init(windowGenerator: .init())
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.toolbar = toolbarController.toolbar
        window?.box.positionCenter()
    }
}

extension NSToolbarItem.Identifier {
    static let back = Self("back")
}

class MainToolbarController: NSObject, NSToolbarDelegate {
    class BackToolbarItem: NSToolbarItem {
        let backButton = ToolbarButton()

        init() {
            super.init(itemIdentifier: .back)
            view = backButton
            backButton.title = ""
            backButton.image = SFSymbol(systemName: .chevronBackward).nsImage
        }
    }

    let toolbar: NSToolbar

    let backItem = BackToolbarItem()
    
    override init() {
        self.toolbar = NSToolbar()
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .sidebarTrackingSeparator]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .back:
            return backItem
        default:
            return nil
        }
    }
}
