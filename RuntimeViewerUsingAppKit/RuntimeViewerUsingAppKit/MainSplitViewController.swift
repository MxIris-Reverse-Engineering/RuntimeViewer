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
}
