import AppKit

extension NSOutlineView {
    /// Expands the given item and its descendants down to the specified depth.
    ///
    /// Complements AppKit's `expandItem(_:expandChildren:)`, which can only expand a single
    /// level or every descendant. Pass `depth` to cap the recursion at a fixed number of levels.
    ///
    /// - Parameters:
    ///   - item: The item to expand, or `nil` to expand the outline view's root items.
    ///   - depth: The number of levels to expand, counting `item` itself as level `1`. A value
    ///     of `1` expands only `item`; `2` also expands its direct children, and so on. Values
    ///     of `0` or below perform no expansion.
    func expandItem(_ item: Any?, toDepth depth: Int) {
        guard depth > 0 else { return }
        expandItem(item)
        guard let dataSource else { return }
        let childCount = dataSource.outlineView?(self, numberOfChildrenOfItem: item) ?? 0
        for childIndex in 0..<childCount {
            guard let childItem = dataSource.outlineView?(self, child: childIndex, ofItem: item) else { continue }
            expandItem(childItem, toDepth: depth - 1)
        }
    }
}
