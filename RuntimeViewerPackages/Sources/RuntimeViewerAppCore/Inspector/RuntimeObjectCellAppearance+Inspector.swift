#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import Foundation
import RuntimeViewerCore

extension RuntimeObjectCellAppearance {
    /// The size of the icons in the Inspector's object rows.
    static let inspectorIconSize: CGFloat = 20

    /// A row of the Inspector's object lists — the Relationships page's
    /// subclasses and conforming types, the Class page's hierarchy: the
    /// object's badges, its name, and under it the image it is in.
    static func inspectorRow(for runtimeObject: RuntimeObject) -> RuntimeObjectCellAppearance {
        let iconSize = inspectorIconSize
        var appearance = RuntimeObjectCellAppearance(
            primaryIcon: RuntimeObjectIcon.icon(for: runtimeObject.kind, size: iconSize),
            primaryTooltip: RuntimeObjectIcon.tooltip(for: runtimeObject.kind),
            secondaryIcon: RuntimeObjectIcon.secondaryIcon(for: runtimeObject, size: iconSize),
            secondaryTooltip: RuntimeObjectIcon.secondaryTooltip(for: runtimeObject),
            title: NSAttributedString(rowText: runtimeObject.displayName, fontSize: 12, color: .labelColor)
        )
        if runtimeObject.properties.contains(.isGeneric) {
            appearance.tertiaryIcon = RuntimeObjectIcon.iconForGeneric(size: iconSize)
            appearance.tertiaryTooltip = RuntimeObjectIcon.tooltipForGeneric
        }
        if runtimeObject.properties.contains(.isSpecialized) {
            appearance.tertiaryIcon = RuntimeObjectIcon.iconForSpecialized(size: iconSize)
            appearance.tertiaryTooltip = RuntimeObjectIcon.tooltipForSpecialized
        }
        let imageName = runtimeObject.imageName
        if !imageName.isEmpty {
            appearance.subtitle = NSAttributedString(rowText: imageName, fontSize: 10, color: .secondaryLabelColor)
        }
        return appearance
    }
}
