#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import MemberwiseInit

/// The complete visual state of a runtime-object cell, published as one value
/// so a high-cardinality cell view model pays for a single Rx stream instead
/// of one per outlet (see proposal 0005).
///
/// The icons are described, not drawn (`IconDescriptor`; the cell view draws
/// them), so copying the struct never copies image storage. `Equatable` lets
/// publishers drop equal-value updates: icons compare as the values they are,
/// the attributed strings compare by content, and each tooltip is a short
/// constant from the same place as its icon.
@MemberwiseInit(.public)
public struct RuntimeObjectCellAppearance: Equatable {
    public var primaryIcon: IconDescriptor? = nil
    public var primaryTooltip: String = .init()

    public var secondaryIcon: IconDescriptor? = nil
    public var secondaryTooltip: String? = nil

    public var tertiaryIcon: IconDescriptor? = nil
    public var tertiaryTooltip: String? = nil

    public var title: NSAttributedString = .init()
    public var subtitle: NSAttributedString? = nil

    /// Tags after the title, in order; see `RuntimeObjectCellTag`.
    public var tags: [RuntimeObjectCellTag] = []
}
