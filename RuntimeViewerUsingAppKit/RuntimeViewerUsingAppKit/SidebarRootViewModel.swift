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

final class SidebarRootCellViewModel: ViewModel<SidebarRoute>, OutlineNodeType, Differentiable {
    let node: RuntimeNamedNode
    
    weak var parent: SidebarRootCellViewModel?
    
    lazy var children: [SidebarRootCellViewModel] = {
        node.children.map { .init(node: $0, parent: self, appServices: appServices, router: router) }
    }()
    
    init(node: RuntimeNamedNode, parent: SidebarRootCellViewModel?, appServices: AppServices, router: UnownedRouter<SidebarRoute>) {
        self.node = node
        super.init(appServices: appServices, router: router)
    }
}

class SidebarRootViewModel: ViewModel<SidebarRoute> {
    let rootNode = CDUtilities.dyldSharedCacheImageRootNode
    
    struct Input {
        let clickedNode: Signal<SidebarRootCellViewModel>
        let selectedNode: Signal<SidebarRootCellViewModel>
    }
    
    struct Output {
        let rootNode: Driver<SidebarRootCellViewModel>
    }
    
    func transform(_ input: Input) -> Output {
        return Output(rootNode: .just(.init(node: rootNode, parent: nil, appServices: appServices, router: router)))
    }
}

extension SidebarRootViewModel: NSOutlineViewDataSource, NSOutlineViewDelegate {
    
}

extension RuntimeNamedNode: OutlineNodeType, Differentiable {}
