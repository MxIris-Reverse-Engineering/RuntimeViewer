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

public final class InspectorRelationshipsCellViewModel: NSObject, @unchecked Sendable {
    public let runtimeObject: RuntimeObject

    @RxObserved
    public private(set) var appearance: RuntimeObjectCellAppearance

    public init(runtimeObject: RuntimeObject) {
        self.runtimeObject = runtimeObject

        let iconSize: CGFloat = 20
        var composedAppearance = RuntimeObjectCellAppearance(
            primaryIcon: RuntimeObjectIcon.icon(for: runtimeObject.kind, size: iconSize),
            secondaryIcon: runtimeObject.secondaryKind.map { RuntimeObjectIcon.icon(for: $0, size: iconSize) },
            title: NSAttributedString {
                AText(runtimeObject.displayName)
                    .foregroundColor(.labelColor)
                    .font(.systemFont(ofSize: 12))
                    .alignment(.left)
                    .lineBreakeMode(.byTruncatingTail)
            }
        )
        if runtimeObject.properties.contains(.isGeneric) {
            composedAppearance.tertiaryIcon = RuntimeObjectIcon.iconForGeneric(size: iconSize)
        }
        if runtimeObject.properties.contains(.isSpecialized) {
            composedAppearance.tertiaryIcon = RuntimeObjectIcon.iconForSpecialized(size: iconSize)
        }
        let imageName = runtimeObject.imageName
        if !imageName.isEmpty {
            composedAppearance.subtitle = NSAttributedString {
                AText(imageName)
                    .foregroundColor(.secondaryLabelColor)
                    .font(.systemFont(ofSize: 10))
                    .alignment(.left)
                    .lineBreakeMode(.byTruncatingTail)
            }
        }
        self.appearance = composedAppearance
        super.init()
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension InspectorRelationshipsCellViewModel: Differentiable {
    public var differenceIdentifier: RuntimeObject { runtimeObject }

    public func isContentEqual(to source: InspectorRelationshipsCellViewModel) -> Bool {
        runtimeObject == source.runtimeObject
    }
}

extension InspectorRelationshipsCellViewModel: RuntimeObjectCellDisplayable {
    public var appearanceDriver: Driver<RuntimeObjectCellAppearance> { $appearance.asDriver() }
}

#endif
