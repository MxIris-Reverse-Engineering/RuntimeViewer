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
import RuntimeViewerUI

final class SidebarRootCellViewModel: ViewModel<SidebarRoute>, OutlineNodeType, Differentiable {
    let node: RuntimeNamedNode
    
    weak var parent: SidebarRootCellViewModel?
    
    lazy var children: [SidebarRootCellViewModel] = {
        let children = node.children.map { SidebarRootCellViewModel(node: $0, parent: self, appServices: appServices, router: router) }
        return children.sorted { $0.node.name < $1.node.name }
    }()
    
    @Observed
    var icon: NSImage?
    
    @Observed
    var name: NSAttributedString
    
    
    init(node: RuntimeNamedNode, parent: SidebarRootCellViewModel?, appServices: AppServices, router: UnownedRouter<SidebarRoute>) {
        self.node = node
        self.name = NSAttributedString {
            AText(node.name.isEmpty ? "Dyld Shared Cache" : node.name)
                .foregroundColor(.labelColor)
                .font(.systemFont(ofSize: 13))
        }
        self.icon = SFSymbol(systemName: node.isLeaf ? .doc : .folder).nsImage
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
