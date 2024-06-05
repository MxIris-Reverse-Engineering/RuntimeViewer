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
    
    func setupBindings(for viewModel: MainViewModel) {
        self.viewModel = viewModel
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        print(Self.automaticDimension)
        view.frame = .init(x: 0, y: 0, width: 1280, height: 800)
        splitView.autosaveName = "\(Self.self).AutosaveName"
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
        splitView.setPosition(250, ofDividerAt: 0)
    }
}
