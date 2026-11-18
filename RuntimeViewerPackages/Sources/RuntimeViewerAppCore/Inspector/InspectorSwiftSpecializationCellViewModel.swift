#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import RxAppKit
#endif

import Foundation
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
            primaryIcon: .runtimeObject(runtimeObject.kind, size: iconSize),
            primaryTooltip: RuntimeObjectIcon.tooltip(for: runtimeObject.kind),
            secondaryIcon: RuntimeObjectIcon.secondaryGlyph(for: runtimeObject, size: iconSize).map(IconDescriptor.glyph),
            secondaryTooltip: RuntimeObjectIcon.secondaryTooltip(for: runtimeObject),
            title: RowText(runtimeObject.displayName, fontSize: 13)
        )
        if runtimeObject.properties.contains(.isGeneric) {
            composedAppearance.tertiaryIcon = .glyph(RuntimeObjectIcon.genericGlyph(size: iconSize))
            composedAppearance.tertiaryTooltip = RuntimeObjectIcon.tooltipForGeneric
        }
        if runtimeObject.properties.contains(.isSpecialized) {
            composedAppearance.tertiaryIcon = .glyph(RuntimeObjectIcon.specializedGlyph(size: iconSize))
            composedAppearance.tertiaryTooltip = RuntimeObjectIcon.tooltipForSpecialized
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
