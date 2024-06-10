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

class SidebarRootViewModel: ViewModel<SidebarRoute> {
    let rootNode = SidebarRootCellViewModel(node: CDUtilities.dyldSharedCacheImageRootNode, parent: nil)

    lazy var allNodes: [String: SidebarRootCellViewModel] = {
        var allNodes: [String: SidebarRootCellViewModel] = [:]
        for node in rootNode {
            allNodes[node.node.path] = node
        }
        return allNodes
    }()

    @Observed
    var searchString: String = ""
    
    
    
    struct Input {
        let clickedNode: Signal<SidebarRootCellViewModel>
        let selectedNode: Signal<SidebarRootCellViewModel>
    }

    struct Output {
        let rootNode: Driver<SidebarRootCellViewModel>
    }

    func transform(_ input: Input) -> Output {
        input.clickedNode.emitOnNextMainActor { [weak self] viewModel in
            guard let self = self else { return }

            if viewModel.node.isLeaf {
                self.router.trigger(.clickedNode(viewModel.node))
            }
        }
        .disposed(by: rx.disposeBag)
        return Output(rootNode: .just(rootNode))
    }
}

extension SidebarRootViewModel: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, itemForPersistentObject object: Any) -> Any? {
        guard let path = object as? String else { return nil }
        return allNodes[path]
    }

    func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any? {
        guard let item = item as? SidebarRootCellViewModel else { return nil }
        return item.node.path
    }
}

extension RuntimeNamedNode: Sequence {
    public func makeIterator() -> Iterator {
        return Iterator(node: self)
    }

    public struct Iterator: IteratorProtocol {
        var stack: [RuntimeNamedNode] = []

        init(node: RuntimeNamedNode) {
            self.stack = [node]
        }

        public mutating func next() -> RuntimeNamedNode? {
            if let node = stack.popLast() {
                stack.append(contentsOf: node.children.reversed())
                return node
            }
            return nil
        }
    }
}

final class SidebarRootCellViewModel: NSObject, OutlineNodeType, Differentiable, Sequence {
    let node: RuntimeNamedNode

    weak var parent: SidebarRootCellViewModel?

    lazy var children: [SidebarRootCellViewModel] = {
        let children = node.children.map { SidebarRootCellViewModel(node: $0, parent: self) }
        return children.sorted { $0.node.name < $1.node.name }
    }()

    @Observed
    var icon: NSImage?

    @Observed
    var name: NSAttributedString

    init(node: RuntimeNamedNode, parent: SidebarRootCellViewModel?) {
        self.node = node
        self.name = NSAttributedString {
            AText(node.name.isEmpty ? "Dyld Shared Cache" : node.name)
                .foregroundColor(.labelColor)
                .font(.systemFont(ofSize: 13))
        }
        self.icon = node.icon
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(node)
        return hasher.finalize()
    }

    override func isEqual(to object: Any?) -> Bool {
        guard let object = object as? Self else { return false }
        return node == object.node
    }

    public func makeIterator() -> Iterator {
        return Iterator(node: self)
    }

    public struct Iterator: IteratorProtocol {
        var stack: [SidebarRootCellViewModel] = []

        init(node: SidebarRootCellViewModel) {
            self.stack = [node]
        }

        @MainActor public mutating func next() -> SidebarRootCellViewModel? {
            if let node = stack.popLast() {
                stack.append(contentsOf: node.children.reversed())
                return node
            }
            return nil
        }
    }

    func search(with term: String) -> [SidebarRootCellViewModel] {
        var results: [SidebarRootCellViewModel] = []

        if node.name.localizedCaseInsensitiveContains(term) {
            results.append(self)
        }

        for child in children {
            results.append(contentsOf: child.search(with: term))
        }

        return results
    }
}

extension RuntimeNamedNode: OutlineNodeType, Differentiable {
    
    static let frameworkIcon = SFSymbol(systemName: .latch2Case).nsImage
    
    static let bundleIcon = SFSymbol(systemName: .shippingbox).nsImage
    
    static let imageIcon = SFSymbol(systemName: .doc).nsImage
    
    static let folderIcon = SFSymbol(systemName: .folder).nsImage
    
    var icon: NSImage {
        if name.hasSuffix("framework") {
            Self.frameworkIcon
        } else if name.hasSuffix("bundle") {
            Self.bundleIcon
        } else if isLeaf {
            Self.imageIcon
        } else {
            Self.folderIcon
        }
    }
    
}
