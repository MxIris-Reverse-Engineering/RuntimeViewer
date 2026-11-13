#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RxAppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import Foundation
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// One level of the Inspector's Hierarchy page: the inspected class or one of
/// its superclasses, or the inspected protocol or one it refines. A level no
/// indexed image defines is known by its name alone and has no object to open.
///
/// A protocol's levels form a tree, so a level carries the ones under it and
/// is a node of the page's outline. Its identifier is its path from the root:
/// one protocol reached along two paths is two levels, each kept apart.
public final class InspectorHierarchyCellViewModel: NSObject, @unchecked Sendable {
    /// The type the level stands for; `nil` when no indexed image defines it.
    public let runtimeObject: RuntimeObject?

    /// The name the level shows.
    public let name: String

    /// The protocols a protocol level refines; none in a class's chain.
    public let children: [InspectorHierarchyCellViewModel]

    /// Where the level stands in its hierarchy, unique within it.
    public let identifier: String

    @RxObserved
    public private(set) var appearance: RuntimeObjectCellAppearance

    public init(runtimeObject: RuntimeObject, children: [InspectorHierarchyCellViewModel] = [], identifier: String) {
        self.runtimeObject = runtimeObject
        self.name = runtimeObject.displayName
        self.children = children
        self.identifier = identifier
        self.appearance = .inspectorRow(for: runtimeObject)
        super.init()
    }

    /// A level known by name only, shown the way the Find navigator shows a
    /// type no indexed image defines: a question mark, the name in grey, and
    /// no image under it. The question mark is a grey badge the size of the
    /// other levels' badges, so the arrows between the levels run straight.
    public init(unresolvedName name: String, children: [InspectorHierarchyCellViewModel] = [], identifier: String) {
        self.runtimeObject = nil
        self.name = name
        self.children = children
        self.identifier = identifier
        self.appearance = RuntimeObjectCellAppearance(
            primaryIcon: RuntimeObjectIcon.icon(text: "?", color: .gray, size: RuntimeObjectCellAppearance.inspectorIconSize),
            primaryTooltip: "Not found in the indexed images",
            title: NSAttributedString {
                AText(name)
                    .foregroundColor(.secondaryLabelColor)
                    .font(.systemFont(ofSize: 12))
                    .alignment(.left)
                    .lineBreakeMode(.byTruncatingTail)
            }
        )
        super.init()
    }

    /// A level the engine answered with, and the levels under it.
    public convenience init(level: RuntimeRelationshipNode, identifier: String) {
        let children = level.children.enumerated().map { index, child in
            InspectorHierarchyCellViewModel(level: child, identifier: Self.identifier(of: child, at: index, under: identifier))
        }
        if let runtimeObject = level.object {
            self.init(runtimeObject: runtimeObject, children: children, identifier: identifier)
        } else {
            self.init(unresolvedName: level.name, children: children, identifier: identifier)
        }
    }

    /// The identifier of the level `index`-th among the levels under the one
    /// `parentIdentifier` names, or among the top levels when it is empty.
    public static func identifier(of level: RuntimeRelationshipNode, at index: Int, under parentIdentifier: String = "") -> String {
        let levelKey = level.object.map { "\($0.kind)|\($0.name)|\($0.imagePath)" } ?? "unresolved|\(level.name)"
        return "\(parentIdentifier)/\(index):\(levelKey)"
    }

    // MARK: - Identity

    /// The same level, whichever instance: the identifiers match. An outline
    /// keeps a row expanded and finds its row only for an item equal to the
    /// one it knows, and every fetch builds new levels.
    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? InspectorHierarchyCellViewModel else { return false }
        return identifier == other.identifier
    }

    public override var hash: Int {
        identifier.hashValue
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension InspectorHierarchyCellViewModel: OutlineNodeType {}

extension InspectorHierarchyCellViewModel: Differentiable {
    public var differenceIdentifier: String { identifier }

    /// Whether the level and every level under it show the same as `source`'s:
    /// the outline's adapter skips a row this calls unchanged, so it has to
    /// look at the whole subtree.
    public func isContentEqual(to source: InspectorHierarchyCellViewModel) -> Bool {
        let isSameLevel = switch (runtimeObject, source.runtimeObject) {
        case (let runtimeObject?, let sourceRuntimeObject?):
            runtimeObject.hasSameContent(as: sourceRuntimeObject)
        case (nil, nil):
            name == source.name
        default:
            false
        }
        guard isSameLevel, children.count == source.children.count else { return false }
        return zip(children, source.children).allSatisfy { child, sourceChild in
            child.identifier == sourceChild.identifier && child.isContentEqual(to: sourceChild)
        }
    }
}

extension InspectorHierarchyCellViewModel: RuntimeObjectCellDisplayable {
    public var appearanceDriver: Driver<RuntimeObjectCellAppearance> { $appearance.asDriver() }
}

#endif
