//
//  MainSplitViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI

class MainSplitViewController: NSSplitViewController {
    var viewModel: MainViewModel?

    private static let autosaveName = "com.JH.RuntimeViewer.MainSplitViewController.autosaveName"

    private static let identifier = "com.JH.RuntimeViewer.MainSplitViewController.identifier"

    func setupBindings(for viewModel: MainViewModel) {
        self.viewModel = viewModel
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.identifier = .init(Self.identifier)
        splitView.autosaveName = Self.autosaveName

        if AppDefaults[\.isInitialSetupSplitView] {
            view.frame = .init(x: 0, y: 0, width: 1280, height: 800)
        }
    }

    @objc func transitionCoordinator() -> Any? {
        return nil
    }

    @objc func _ancestorViewControllerOfClass(_ class: Any?) -> Any? {
        return nil
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
}
