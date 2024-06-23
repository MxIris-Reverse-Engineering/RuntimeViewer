//
//  ViewController.swift
//  RuntimeViewerUsingUIKit
//
//  Created by JH on 2024/6/3.
//

import UIKit
import RuntimeViewerUI

class ViewController<ViewModelType>: UIViewController {
    var viewModel: ViewModelType?
    
    func setupBindings(for viewModel: ViewModelType) {
        self.viewModel = viewModel
    }
}
