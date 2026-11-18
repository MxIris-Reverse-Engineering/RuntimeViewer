import MemberwiseInit

/// The complete visual state of a runtime-object cell, published as one value
/// so a high-cardinality cell view model pays for a single Rx stream instead
/// of one per outlet (see proposal 0005).
///
/// Everything is described, not drawn — the icons as `IconDescriptor`s, the
/// title and subtitle as `RowText` — and the cell view draws them (proposal
/// `app-core-without-ui-models`). `Equatable` lets publishers drop equal-value
/// updates: everything compares as the value it is, and each tooltip is a
/// short constant from the same place as its icon.
@MemberwiseInit(.public)
public struct RuntimeObjectCellAppearance: Equatable {
    public var primaryIcon: IconDescriptor? = nil
    public var primaryTooltip: String = .init()

    public var secondaryIcon: IconDescriptor? = nil
    public var secondaryTooltip: String? = nil

    public var tertiaryIcon: IconDescriptor? = nil
    public var tertiaryTooltip: String? = nil

    public var title: RowText = .empty
    public var subtitle: RowText? = nil

    /// Tags after the title, in order; see `RuntimeObjectCellTag`.
    public var tags: [RuntimeObjectCellTag] = []
}
