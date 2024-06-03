//
//  SidebarViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI

class SidebarRootViewController: ViewController<SidebarRootViewModel> {
    let (scrollView, outlineView): (ScrollView, OutlineView) = OutlineView.scrollableOutlineView()

    override func viewDidLoad() {
        super.viewDidLoad()
        hierarchy {
            scrollView
        }

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }
}




