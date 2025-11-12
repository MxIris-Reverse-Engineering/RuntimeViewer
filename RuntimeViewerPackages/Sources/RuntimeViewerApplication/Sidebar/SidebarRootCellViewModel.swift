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

public final class SidebarRootCellViewModel: NSObject, Sequence, OutlineNodeType {
    public let node: RuntimeImageNode

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

    public init(node: RuntimeImageNode, parent: SidebarRootCellViewModel?) {
        self.node = node
        self.parent = parent
        self.name = NSAttributedString {
            AText(node.name)
                .foregroundColor(.labelColor)
                .font(.systemFont(ofSize: 13))
        }
        self.icon = node.icon
    }

//    public override var hash: Int {
//        var hasher = Hasher()
//        hasher.combine(node)
//        return hasher.finalize()
//    }
//
//    public override func isEqual(_ object: Any?) -> Bool {
//        guard let object = object as? Self else { return false }
//        return node == object.node
//    }

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
