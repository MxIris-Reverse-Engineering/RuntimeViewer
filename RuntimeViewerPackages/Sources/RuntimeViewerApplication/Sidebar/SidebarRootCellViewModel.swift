#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RxAppKit
#endif

#if canImport(UIKit)
import UIKit
import Foundation
#endif

import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerUI
import Ifrit

public final class SidebarRootCellViewModel: NSObject, OutlineNodeType, @unchecked Sendable {
    public let node: RuntimeImageNode

    public weak var parent: SidebarRootCellViewModel?

    public var children: [SidebarRootCellViewModel] { _filteredChildren }

    public var isLeaf: Bool { children.isEmpty }

    private lazy var _filteredChildren: [SidebarRootCellViewModel] = _children

    private lazy var _children: [SidebarRootCellViewModel] = {
        let children = node.children.map { SidebarRootCellViewModel(node: $0, parent: self) }
        return children.sorted { $0.node.name < $1.node.name }
    }()

    public private(set) lazy var currentAndChildrenNames: String = {
        let childrenNames = _children.map { $0.currentAndChildrenNames }.joined(separator: " ")
        if childrenNames.isEmpty {
            return node.name
        } else {
            return "\(node.name) \(childrenNames)"
        }
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
                .paragraphStyle(NSMutableParagraphStyle().then { $0.lineBreakMode = .byTruncatingTail })
        }
        self.icon = node.icon
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
