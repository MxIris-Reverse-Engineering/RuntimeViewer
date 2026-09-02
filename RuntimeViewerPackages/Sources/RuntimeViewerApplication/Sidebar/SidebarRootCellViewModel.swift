#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RxAppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures

public final class SidebarRootCellViewModel: NSObject, OutlineNodeType, @unchecked Sendable {
    public let node: RuntimeImageNode

    public var children: [SidebarRootCellViewModel] {
        set {
            _children = newValue
            _filteredChildren = _children
        }
        get {
            _filteredChildren
        }
    }

    public var isLeaf: Bool { children.isEmpty }

    private lazy var _filteredChildren: [SidebarRootCellViewModel] = _children

    private lazy var _children: [SidebarRootCellViewModel] = {
        let children = node.children.map { SidebarRootCellViewModel(node: $0) }
        return children.sorted { $0.node.name < $1.node.name }
    }()

    /// The unfiltered child list. The root filter pipeline
    /// (`SidebarRootFilterPipeline`) snapshots and re-applies against this
    /// array so an active filter never hides nodes from its own
    /// recomputation. Filtering itself has no mutating cascade anymore —
    /// the pipeline computes every level off-main and installs the
    /// results through `applyFilterOutcome(filteredChildren:)`.
    var unfilteredChildren: [SidebarRootCellViewModel] { _children }

    /// Single entry point for the root filter pipeline's main-actor apply
    /// step: installs the pre-computed filtered children without any
    /// cascade or string matching.
    func applyFilterOutcome(filteredChildren: [SidebarRootCellViewModel]) {
        _filteredChildren = filteredChildren
    }


    /// Both display outlets in one stream: the image list keeps ~13k of these
    /// rows resident, so per-row Rx fixed cost matters (proposal 0005).
    public struct Appearance: Equatable {
        public var icon: NSUIImage?
        public var name: NSAttributedString

        public init(icon: NSUIImage?, name: NSAttributedString) {
            self.icon = icon
            self.name = name
        }
    }

    @Observed
    public private(set) var appearance: Appearance

    /// Whether `$appearance` has been materialized. The image list filter and
    /// type-select must leave this `false`; only a cell view binding the row
    /// should flip it. Guarded by `SidebarFilterRelayMaterializationTests`.
    package var hasMaterializedAppearanceRelay: Bool {
        _appearance.hasMaterializedRelay
    }

    public init(node: RuntimeImageNode) {
        self.node = node
        self.appearance = Appearance(
            icon: node.icon,
            name: NSAttributedString {
                AText(node.name)
                    .font(.systemFont(ofSize: 13))
                    .alignment(.left)
                    .lineBreakeMode(.byTruncatingTail)
            }
        )
    }

    public func makeIterator() -> Iterator {
        return Iterator(node: self)
    }
    
//    func applyMove(to roots: inout [Self]) {
//        
//    }

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
