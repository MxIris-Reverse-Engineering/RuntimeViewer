//
//  SidebarImageViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures

class SidebarImageViewController: ViewController<SidebarImageViewModel> {
    override func viewDidLoad() {
        super.viewDidLoad()

        uxView.setValue(NSColor.windowBackgroundColor, forKeyPath: "backgroundColor")
    }
}
