//
//  SidebarImageViewModel.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures

class SidebarImageViewModel: ViewModel<SidebarRoute> {
    let node: RuntimeNamedNode
    
    init(node: RuntimeNamedNode, appServices: AppServices, router: UnownedRouter<SidebarRoute>) {
        self.node = node
        super.init(appServices: appServices, router: router)
    }
}
