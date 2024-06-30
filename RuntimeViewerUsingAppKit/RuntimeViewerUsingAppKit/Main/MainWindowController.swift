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
    static let identifier: NSUserInterfaceItemIdentifier = "com.JH.RuntimeViewer.MainWindow"
    static let frameAutosaveName = "com.JH.RuntimeViewer.MainWindow.FrameAutosaveName"

    init() {
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    }
}

class MainWindowController: XiblessWindowController<MainWindow> {
    lazy var toolbarController = MainToolbarController(delegate: self)

    lazy var splitViewController = MainSplitViewController()

    var viewModel: MainViewModel?

    func setupBindings(for viewModel: MainViewModel) {
        self.viewModel = viewModel

        let input = MainViewModel.Input(
            sidebarBackClick: toolbarController.backItem.backButton.rx.click.asSignal(),
            saveClick: toolbarController.saveItem.saveButton.rx.click.asSignal(),
            switchSource: toolbarController.switchSourceItem.segmentedControl.rx.selectedSegment.asSignal(),
            generationOptionsClick: toolbarController.generationOptionsItem.button.rx.clickWithSelf.asSignal().map { $0 }
        )
        let output = viewModel.transform(input)
        output.sharingServiceItems.bind(to: toolbarController.sharingServicePickerItem.rx.items).disposed(by: rx.disposeBag)
        output.isSavable.drive(toolbarController.saveItem.saveButton.rx.isEnabled).disposed(by: rx.disposeBag)
    }

    init() {
        super.init(windowGenerator: .init())
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        contentWindow.toolbar = toolbarController.toolbar
        contentWindow.identifier = MainWindow.identifier
        contentWindow.setFrame(.init(origin: .zero, size: .init(width: 1280, height: 800)), display: true)
        contentWindow.box.positionCenter()
        contentWindow.setFrameAutosaveName(MainWindow.frameAutosaveName)
    }
}

extension MainWindowController: MainToolbarController.Delegate {
    var splitView: NSSplitView {
        splitViewController.splitView
    }
}
