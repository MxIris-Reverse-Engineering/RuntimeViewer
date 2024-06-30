//
//  ViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI

class UXKitViewController<ViewModelType>: UXViewController {
    var viewModel: ViewModelType?
    
    func setupBindings(for viewModel: ViewModelType) {
        self.viewModel = viewModel
    }
}


class AppKitViewController<ViewModelType>: NSViewController {
    var viewModel: ViewModelType?
    
    func setupBindings(for viewModel: ViewModelType) {
        self.viewModel = viewModel
    }
}
