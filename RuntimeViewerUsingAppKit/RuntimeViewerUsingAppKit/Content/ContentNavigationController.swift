//
//  ContentNavigationController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI

class ContentNavigationController: UXNavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        
        isToolbarHidden = true
        isNavigationBarHidden = true
        view.canDrawSubviewsIntoLayer = true
    }
}
