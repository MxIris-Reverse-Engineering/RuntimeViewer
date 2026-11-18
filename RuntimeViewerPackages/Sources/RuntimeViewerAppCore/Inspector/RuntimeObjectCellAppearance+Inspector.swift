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
            primaryIcon: .runtimeObject(runtimeObject.kind, size: iconSize),
            primaryTooltip: RuntimeObjectIcon.tooltip(for: runtimeObject.kind),
            secondaryIcon: RuntimeObjectIcon.secondaryGlyph(for: runtimeObject, size: iconSize).map(IconDescriptor.glyph),
            secondaryTooltip: RuntimeObjectIcon.secondaryTooltip(for: runtimeObject),
            title: RowText(runtimeObject.displayName, fontSize: 12)
        )
        if runtimeObject.properties.contains(.isGeneric) {
            appearance.tertiaryIcon = .glyph(RuntimeObjectIcon.genericGlyph(size: iconSize))
            appearance.tertiaryTooltip = RuntimeObjectIcon.tooltipForGeneric
        }
        if runtimeObject.properties.contains(.isSpecialized) {
            appearance.tertiaryIcon = .glyph(RuntimeObjectIcon.specializedGlyph(size: iconSize))
            appearance.tertiaryTooltip = RuntimeObjectIcon.tooltipForSpecialized
        }
        let imageName = runtimeObject.imageName
        if !imageName.isEmpty {
            appearance.subtitle = RowText(imageName, role: .secondary, fontSize: 10)
        }
        return appearance
    }
}
