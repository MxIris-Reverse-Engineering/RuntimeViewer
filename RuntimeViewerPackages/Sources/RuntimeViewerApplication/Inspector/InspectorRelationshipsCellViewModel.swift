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

    @Observed
    public private(set) var primaryIcon: NSUIImage

    @Observed
    public private(set) var secondaryIcon: NSUIImage?

    @Observed
    public private(set) var tertiaryIcon: NSUIImage?

    @Observed
    public private(set) var title: NSAttributedString

    @Observed
    public private(set) var subtitle: NSAttributedString?

    public init(runtimeObject: RuntimeObject) {
        self.runtimeObject = runtimeObject
        
        let iconSize = RuntimeObjectIcon.defaultIconSize
        primaryIcon = RuntimeObjectIcon.icon(for: runtimeObject.kind, size: iconSize)
        secondaryIcon = runtimeObject.secondaryKind.map { RuntimeObjectIcon.icon(for: $0, size: iconSize) }
        if runtimeObject.properties.contains(.isGeneric) {
            tertiaryIcon = RuntimeObjectIcon.iconForGeneric(size: iconSize)
        }
        if runtimeObject.properties.contains(.isSpecialized) {
            tertiaryIcon = RuntimeObjectIcon.iconForSpecialized(size: iconSize)
        }
        title = NSAttributedString {
            AText(runtimeObject.displayName)
                .foregroundColor(.labelColor)
                .font(.systemFont(ofSize: 12))
                .alignment(.left)
                .lineBreakeMode(.byTruncatingTail)
        }
        let imageName = runtimeObject.imageName
        if !imageName.isEmpty {
            subtitle = NSAttributedString {
                AText(imageName)
                    .foregroundColor(.secondaryLabelColor)
                    .font(.systemFont(ofSize: 10))
                    .alignment(.left)
                    .lineBreakeMode(.byTruncatingTail)
            }
        }
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
    public var primaryIconDriver: Driver<NSUIImage> { $primaryIcon.asDriver() }
    public var secondaryIconDriver: Driver<NSUIImage?> { $secondaryIcon.asDriver() }
    public var tertiaryIconDriver: Driver<NSUIImage?> { $tertiaryIcon.asDriver() }
    public var titleDriver: Driver<NSAttributedString> { $title.asDriver() }
    public var subtitleDriver: Driver<NSAttributedString?> { $subtitle.asDriver() }
}

#endif
