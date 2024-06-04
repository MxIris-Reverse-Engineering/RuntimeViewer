//
//  SidebarRootViewModel.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RxAppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures

class SidebarRootViewModel: ViewModel<SidebarRoute> {
    let rootNode = CDUtilities.dyldSharedCacheImageRootNode
    
    struct Input {
        let clickedNode: Signal<RuntimeNamedNode>
        let selectedNode: Signal<RuntimeNamedNode>
    }
    
    struct Output {
        let rootNode: Driver<RuntimeNamedNode>
    }
    
    func transform(_ input: Input) -> Output {
        return Output(rootNode: .just(rootNode))
    }
}

extension SidebarRootViewModel: NSOutlineViewDataSource, NSOutlineViewDelegate {
    
}

extension RuntimeNamedNode: OutlineNodeType, Differentiable {}
