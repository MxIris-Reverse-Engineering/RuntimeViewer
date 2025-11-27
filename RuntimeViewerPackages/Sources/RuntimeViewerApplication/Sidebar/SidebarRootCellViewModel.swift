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

public final class SidebarRootCellViewModel: NSObject, OutlineNodeType, Searchable, @unchecked Sendable {
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

    var filterResult: FuzzySrchResult? {
        didSet {
            if let filterResult {
                let name = NSMutableAttributedString {
                    AText(node.name)
                        .font(.systemFont(ofSize: 13))
                        .foregroundColor(.tertiaryLabelColor)
                }
                guard let range = currentAndChildrenNames.ranges(of: node.name).first else {
                    self.name = name
                    return
                }
                let currentNSRange = NSRange(currentAndChildrenNames.integerRange(from: range))
                filterResult.results.flatMap { $0.ranges }.forEach { (range: CountableClosedRange<Int>) in
                    let resultNSRange = NSRange(range)
                    guard resultNSRange.location >= currentNSRange.location, NSMaxRange(resultNSRange) <= NSMaxRange(currentNSRange) else { return }
                    name.addAttributes([
                        .foregroundColor: NSUIColor.labelColor,
                        .font: NSUIFont.systemFont(ofSize: 13, weight: .semibold),
                    ], range: resultNSRange)
                }
                self.name = name
            } else {
                name = NSAttributedString {
                    AText(node.name)
                        .foregroundColor(.labelColor)
                        .font(.systemFont(ofSize: 13))
                }
            }
        }
    }
    var searchableProperties: [FuseProp] {
        [
            FuseProp(currentAndChildrenNames)
        ]
    }
    var filter: String = "" {
        didSet {
            if filter.isEmpty {
                _children.forEach { $0.filter = filter }
                _filteredChildren = _children
            } else {
                _children.forEach { $0.filter = filter }
                _filteredChildren = _children.filter { $0.currentAndChildrenNames.localizedCaseInsensitiveContains(filter) }
//                let fuse = Fuse(distance: currentAndChildrenNames.count, tokenize: true)
//                let results = fuse.searchSync(filter, in: _children, by: \.searchableProperties).sorted { $0.diffScore < $1.diffScore }
//                var filteredChildren: [SidebarRootCellViewModel] = []
//                for result in results {
//                    let cellViewModel = _children[result.index]
//                    cellViewModel.filterResult = result
//                    filteredChildren.append(cellViewModel)
//                }
//                _filteredChildren = filteredChildren
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
