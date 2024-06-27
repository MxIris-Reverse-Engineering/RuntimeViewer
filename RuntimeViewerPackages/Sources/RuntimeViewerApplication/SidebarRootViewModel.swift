#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RxAppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerUI

public final class SidebarRootViewModel: ViewModel<SidebarRoute> {
    @Observed
    private var nodes: [SidebarRootCellViewModel] = []

    @Observed
    private var filteredRootNode: SidebarRootCellViewModel? = nil

    private lazy var allNodes: [String: SidebarRootCellViewModel] = {
        var allNodes: [String: SidebarRootCellViewModel] = [:]
        for rootNode in nodes {
            for node in rootNode {
                allNodes[node.node.path] = node
            }
        }
        return allNodes
    }()

    @Observed
    private var searchString: String = ""

    public override init(appServices: AppServices, router: any Router<SidebarRoute>) {
        super.init(appServices: appServices, router: router)
        appServices.runtimeListings.$dyldSharedCacheImageNodes.asObservable().observe(on: MainScheduler.instance).map { $0.map { SidebarRootCellViewModel(node: $0, parent: nil) } }.bind(to: $nodes).disposed(by: rx.disposeBag)
    }
    
    public struct Input {
        public let clickedNode: Signal<SidebarRootCellViewModel>
        public let selectedNode: Signal<SidebarRootCellViewModel>
        public let searchString: Signal<String>
        public init(clickedNode: Signal<SidebarRootCellViewModel>, selectedNode: Signal<SidebarRootCellViewModel>, searchString: Signal<String>) {
            self.clickedNode = clickedNode
            self.selectedNode = selectedNode
            self.searchString = searchString
        }
    }

    public struct Output {
        public let nodes: Driver<[SidebarRootCellViewModel]>
        #if canImport(UIKit)
        public let filteredRootNode: Driver<SidebarRootCellViewModel?>
        #endif
    }

    public func transform(_ input: Input) -> Output {
        input.clickedNode.emitOnNextMainActor { [weak self] viewModel in
            guard let self = self else { return }

            if viewModel.node.isLeaf {
                self.router.trigger(.clickedNode(viewModel.node))
            }
        }
        .disposed(by: rx.disposeBag)
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        input.searchString.emit(with: self) {
            $0.nodes.first?.filter = $1
            $0.nodes = $0.nodes
        }.disposed(by: rx.disposeBag)
        return Output(nodes: $nodes.asDriver())
        #endif

        #if canImport(UIKit)

        input.searchString.emit(with: self) { target, searchString in
            if searchString.isEmpty {
                target.filteredRootNode = nil
            } else {
                let rootNode = SidebarRootCellViewModel(node: CDUtilities.dyldSharedCacheImageRootNode, parent: nil)
                rootNode.filter = searchString
                target.filteredRootNode = rootNode
            }
        }.disposed(by: rx.disposeBag)
        
        return Output(rootNode: $rootNode.asDriver(), filteredRootNode: $filteredRootNode.asDriver())
        
        #endif
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension SidebarRootViewModel: NSOutlineViewDataSource {
    public func outlineView(_ outlineView: NSOutlineView, itemForPersistentObject object: Any) -> Any? {
        guard let path = object as? String else { return nil }
        return allNodes[path]
    }

    public func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any? {
        guard let item = item as? SidebarRootCellViewModel else { return nil }
        return item.node.path
    }
}
#endif

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

public final class SidebarRootCellViewModel: NSObject, Sequence, OutlineNodeType {
    public let node: RuntimeNamedNode

    public weak var parent: SidebarRootCellViewModel?

    public var children: [SidebarRootCellViewModel] { _filteredChildren }

    public var isLeaf: Bool { children.isEmpty }

    private lazy var _filteredChildren: [SidebarRootCellViewModel] = _children

    private lazy var _children: [SidebarRootCellViewModel] = {
        let children = node.children.map { SidebarRootCellViewModel(node: $0, parent: self) }
        return children.sorted { $0.node.name < $1.node.name }
    }()

    private lazy var currentAndChildrenNames: String = {
        let childrenNames = _children.map { $0.currentAndChildrenNames }.joined(separator: " ")
        return "\(node.name) \(childrenNames)"
    }()

    var filter: String = "" {
        didSet {
            if filter.isEmpty {
                _children.forEach { $0.filter = filter }
                _filteredChildren = _children
            } else {
                _children.forEach { $0.filter = filter }
                _filteredChildren = _children.filter { $0.currentAndChildrenNames.localizedCaseInsensitiveContains(filter) }
            }
        }
    }

    @Observed
    public private(set) var icon: NSUIImage?

    @Observed
    public private(set) var name: NSAttributedString

    public init(node: RuntimeNamedNode, parent: SidebarRootCellViewModel?) {
        self.node = node
        self.name = NSAttributedString {
            AText(node.name.isEmpty ? "Dyld Shared Cache" : node.name)
                .foregroundColor(.labelColor)
                .font(.systemFont(ofSize: 13))
        }
        self.icon = node.icon
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(node)
        return hasher.finalize()
    }

    public override func isEqual(_ object: Any?) -> Bool {
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

        public mutating func next() -> SidebarRootCellViewModel? {
            if let node = stack.popLast() {
                stack.append(contentsOf: node.children.reversed())
                return node
            }
            return nil
        }
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension SidebarRootCellViewModel: Differentiable {}

#endif

extension RuntimeNamedNode {
    public static let frameworkIcon = SFSymbol(systemName: .latch2Case).nsuiImage

    public static let bundleIcon = SFSymbol(systemName: .shippingbox).nsuiImage

    public static let imageIcon = SFSymbol(systemName: .doc).nsuiImage

    public static let folderIcon = SFSymbol(systemName: .folder).nsuiImage

    public var icon: NSUIImage {
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

extension SFSymbol {
    public var nsuiImage: NSUIImage {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return nsImage
        #endif

        #if canImport(UIKit)
        return uiImage
        #endif
    }
}
