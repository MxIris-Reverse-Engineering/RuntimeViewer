//
//  MainSplitViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication

class MainSplitViewController: NSSplitViewController {
    var viewModel: MainViewModel?

    private static let autosaveName = "com.JH.RuntimeViewer.MainSplitViewController.autosaveName"

    private static let identifier = "com.JH.RuntimeViewer.MainSplitViewController.identifier"

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.identifier = .init(Self.identifier)
        splitView.autosaveName = Self.autosaveName

        if AppDefaults[\.isInitialSetupSplitView] {
            view.frame = .init(x: 0, y: 0, width: 1280, height: 800)
        }
    }

    func setupSplitViewItems() {
        splitViewItems[0].do {
            $0.minimumThickness = 250
            $0.maximumThickness = 400
        }

        splitViewItems[1].do {
            $0.minimumThickness = 600
        }

        splitViewItems[2].do {
            $0.minimumThickness = 200
        }

        if AppDefaults[\.isInitialSetupSplitView] {
            splitView.setPosition(250, ofDividerAt: 0)
            AppDefaults[\.isInitialSetupSplitView] = false
        }
    }

    @objc func _toggleInspector(_ sender: Any?) {
        guard let inspectorItem = splitViewItems.filter({ $0.behavior == .inspector }).first else { return }
        inspectorItem.animator().isCollapsed = !inspectorItem.isCollapsed
    }
}

/* Fix UXKit Exception
extension NSViewController {
    @objc func transitionCoordinator() -> Any? {
        return nil
    }

    @objc func _ancestorViewControllerOfClass(_ class: Any?) -> Any? {
        return nil
    }
}
*/
