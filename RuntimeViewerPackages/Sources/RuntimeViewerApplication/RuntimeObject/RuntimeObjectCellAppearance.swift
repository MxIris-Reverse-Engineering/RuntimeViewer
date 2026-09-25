#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import RuntimeViewerUI
import MemberwiseInit

/// The complete visual state of a runtime-object cell, published as one value
/// so a high-cardinality cell view model pays for a single Rx stream instead
/// of one per outlet (see proposal 0005).
///
/// Every member is a reference, an Optional reference or a `String`, so
/// copying the struct never copies image or text storage. `Equatable` lets
/// publishers drop equal-value updates: icons come from `RuntimeObjectIcon`'s
/// cache (pointer equality holds for unchanged icons), the attributed strings
/// compare by content, and each tooltip is a short constant from the same
/// place as its icon.
@MemberwiseInit(.public)
public struct RuntimeObjectCellAppearance: Equatable {
    public var primaryIcon: NSUIImage = .init()
    public var primaryTooltip: String = .init()

    public var secondaryIcon: NSUIImage? = nil
    public var secondaryTooltip: String? = nil

    public var tertiaryIcon: NSUIImage? = nil
    public var tertiaryTooltip: String? = nil

    public var title: NSAttributedString = .init()
    public var subtitle: NSAttributedString? = nil
}
