#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import RuntimeViewerUI

/// The complete visual state of a runtime-object cell, published as one value
/// so a high-cardinality cell view model pays for a single Rx stream instead
/// of one per outlet (see proposal 0005).
///
/// Every member is a reference (or Optional reference), so copying the struct
/// copies references only. `Equatable` lets publishers drop equal-value
/// updates: icons come from `RuntimeObjectIcon`'s cache (pointer equality
/// holds for unchanged icons) and the attributed strings compare by content.
public struct RuntimeObjectCellAppearance: Equatable {
    public var primaryIcon: NSUIImage
    public var secondaryIcon: NSUIImage?
    public var tertiaryIcon: NSUIImage?
    public var title: NSAttributedString
    public var subtitle: NSAttributedString?

    public init(
        primaryIcon: NSUIImage = .init(),
        secondaryIcon: NSUIImage? = nil,
        tertiaryIcon: NSUIImage? = nil,
        title: NSAttributedString = .init(),
        subtitle: NSAttributedString? = nil
    ) {
        self.primaryIcon = primaryIcon
        self.secondaryIcon = secondaryIcon
        self.tertiaryIcon = tertiaryIcon
        self.title = title
        self.subtitle = subtitle
    }
}
