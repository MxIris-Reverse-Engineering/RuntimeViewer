#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RxSwift
import RxCocoa
import RxAppKit

/// One row the user chose in an outline, with the event that chose it.
public struct OutlineViewUserActivation<Item> {
    public let item: Item
    /// The click or keystroke that made the selection; `nil` when AppKit reports none.
    public let triggeringEvent: NSEvent?
}

extension Reactive where Base: NSOutlineView {
    /// The single row the user selects — by click, arrow key or type-select — with the event
    /// that selected it.
    ///
    /// Backed by `proposedSelection()`, which AppKit consults for the user's own selection
    /// changes only, so a reload, `selectRowIndexes(_:byExtendingSelection:)` and the selection a
    /// list puts back after its rows change never emit — unlike `modelSelected()`, which reports
    /// every selection change and so turns a list that restores its selection into one that
    /// navigates on its own. Neither does a selection of several rows (⌘- or ⇧-click, ⌘A): there
    /// is no one row to act on.
    public func userActivatedItem<Item>(_ itemType: Item.Type = Item.self) -> ControlEvent<OutlineViewUserActivation<Item>> {
        let source = proposedSelection().compactMap { [weak base] proposedSelection -> OutlineViewUserActivation<Item>? in
            guard let base,
                  proposedSelection.indexes.count == 1,
                  let row = proposedSelection.indexes.first,
                  let item = base.item(atRow: row) as? Item
            else { return nil }
            return OutlineViewUserActivation(item: item, triggeringEvent: proposedSelection.triggeringEvent)
        }
        return ControlEvent(events: source)
    }
}
#endif
