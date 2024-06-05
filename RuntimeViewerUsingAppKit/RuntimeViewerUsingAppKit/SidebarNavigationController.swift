//
//  SidebarNavigationController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI

class SidebarNavigationController: UXNavigationController {
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        isToolbarHidden = true
        isNavigationBarHidden = true
    }
}
