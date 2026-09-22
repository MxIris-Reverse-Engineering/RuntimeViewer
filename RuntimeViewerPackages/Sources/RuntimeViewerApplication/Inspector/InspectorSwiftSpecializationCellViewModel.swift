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

public final class InspectorSwiftSpecializationCellViewModel: NSObject, @unchecked Sendable {
    public let runtimeObject: RuntimeObject

    @RxObserved
    public private(set) var appearance: RuntimeObjectCellAppearance

    public init(runtimeObject: RuntimeObject) {
        self.runtimeObject = runtimeObject
        let iconSize = RuntimeObjectIcon.defaultIconSize
        var composedAppearance = RuntimeObjectCellAppearance(
            primaryIcon: RuntimeObjectIcon.icon(for: runtimeObject.kind, size: iconSize),
            secondaryIcon: RuntimeObjectIcon.secondaryIcon(for: runtimeObject, size: iconSize),
            title: NSAttributedString {
                AText(runtimeObject.displayName)
                    .foregroundColor(.labelColor)
                    .font(.systemFont(ofSize: 13))
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
        self.appearance = composedAppearance
        super.init()
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension InspectorSwiftSpecializationCellViewModel: Differentiable {
    public var differenceIdentifier: RuntimeObjectKey { runtimeObject.key }

    public func isContentEqual(to source: InspectorSwiftSpecializationCellViewModel) -> Bool {
        runtimeObject.hasSameContent(as: source.runtimeObject)
    }
}

extension InspectorSwiftSpecializationCellViewModel: RuntimeObjectCellDisplayable {
    public var appearanceDriver: Driver<RuntimeObjectCellAppearance> { $appearance.asDriver() }
}

#endif
