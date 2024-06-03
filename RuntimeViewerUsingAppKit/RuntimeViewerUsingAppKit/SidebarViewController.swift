//
//  SidebarViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI

class SidebarViewController: XiblessViewController<NSView> {
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

import RuntimeViewerCore
import RxRuntimeViewer

enum SidebarRoute: Routable {
    case root
    case node(RuntimeNamedNode)
}



class SidebarViewModel: ViewModel<SidebarRoute> {
    let rootNode = CDUtilities.dyldSharedCacheImageRootNode
}


class ViewModel<Route: Routable>: NSObject {
    let router: UnownedRouter<Route>
    
    init(router: UnownedRouter<Route>) {
        self.router = router
        super.init()
    }
}
