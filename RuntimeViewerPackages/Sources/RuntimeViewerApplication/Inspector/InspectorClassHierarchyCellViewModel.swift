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

/// One level of the Class page's hierarchy: the inspected class, or one of its
/// superclasses. A level no indexed image defines is known by its name alone
/// and has no object to open.
public final class InspectorClassHierarchyCellViewModel: NSObject, @unchecked Sendable {
    /// The class the level stands for; `nil` when no indexed image defines it.
    public let runtimeObject: RuntimeObject?

    /// The name the level shows.
    public let name: String

    @RxObserved
    public private(set) var appearance: RuntimeObjectCellAppearance

    public init(runtimeObject: RuntimeObject) {
        self.runtimeObject = runtimeObject
        self.name = runtimeObject.displayName
        self.appearance = .inspectorRow(for: runtimeObject)
        super.init()
    }

    /// A level known by name only, shown the way the Find navigator shows a
    /// type no indexed image defines: a question mark, the name in grey, and
    /// no image under it. The question mark is a grey badge the size of the
    /// other levels' badges, so the arrows between the levels run straight.
    public init(unresolvedName name: String) {
        self.runtimeObject = nil
        self.name = name
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

    /// A level of the engine's superclass chain.
    public convenience init(level: RuntimeRelationshipNode) {
        if let runtimeObject = level.object {
            self.init(runtimeObject: runtimeObject)
        } else {
            self.init(unresolvedName: level.name)
        }
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension InspectorClassHierarchyCellViewModel: Differentiable {
    /// A level is its class when an indexed image defines one, its name
    /// otherwise; a chain names no class twice.
    public enum Identity: Hashable {
        case object(RuntimeObjectKey)
        case unresolved(name: String)
    }

    public var differenceIdentifier: Identity {
        if let runtimeObject {
            .object(runtimeObject.key)
        } else {
            .unresolved(name: name)
        }
    }

    public func isContentEqual(to source: InspectorClassHierarchyCellViewModel) -> Bool {
        switch (runtimeObject, source.runtimeObject) {
        case (let runtimeObject?, let sourceRuntimeObject?):
            runtimeObject.hasSameContent(as: sourceRuntimeObject)
        case (nil, nil):
            name == source.name
        default:
            false
        }
    }
}

extension InspectorClassHierarchyCellViewModel: RuntimeObjectCellDisplayable {
    public var appearanceDriver: Driver<RuntimeObjectCellAppearance> { $appearance.asDriver() }
}

#endif
