#if os(macOS)

import AppKit
import UIFoundation

extension SelfSizingTableView {
    /// Builds a *navigation list*: a `SelfSizingTableView` inside a
    /// `SelfSizingScrollView`, sized to its rows and configured so that
    /// clicking a row navigates away without leaving a highlight behind.
    ///
    /// Two of those settings are load-bearing and fix **different** flickers —
    /// keep both:
    ///
    /// - `refusesFirstResponder` leaves keyboard focus where it was, so the
    ///   view the user is actually watching (the sidebar) keeps its emphasized
    ///   selection. Without it the click hands focus over and straight back,
    ///   and `NSTableRowView.isEmphasized` turns that round trip into a grey
    ///   blink on the row being looked at.
    /// - `selectionHighlightStyle = .none` removes *this* list's own highlight.
    ///   Refusing first responder only blocks focus: AppKit still selects the
    ///   clicked row and paints it in the unemphasized grey for the frame
    ///   before the navigation replaces the list.
    ///
    /// Only use this where nothing reads the selection. `itemClicked()` reports
    /// `clickedRow` and is unaffected, but `itemSelected()` / `modelSelected()`
    /// / `selectedRow` are — a picker whose highlight marks the current
    /// candidate, or a list whose selection *is* the state, must not use this.
    public static func scrollableNavigationListTableView() -> (scrollView: SelfSizingScrollView, tableView: SelfSizingTableView) {
        let (scrollView, tableView): (SelfSizingScrollView, SelfSizingTableView) = SelfSizingTableView.scrollableTableView()

        tableView.do {
            $0.backgroundColor = .clear
            $0.headerView = nil
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
            $0.usesAutomaticRowHeights = true
            $0.style = .inset
            $0.refusesFirstResponder = true
            // Assign after `style`: setting `NSTableView.style` resets the
            // highlight style, so the reverse order silently does nothing.
            $0.selectionHighlightStyle = .none
        }

        scrollView.do {
            $0.isHiddenVisualEffectView = true
            $0.autohidesScrollers = true
            $0.backgroundColor = .clear
            $0.minimumContentSize.height = 80
            $0.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }

        return (scrollView, tableView)
    }
}

#endif
