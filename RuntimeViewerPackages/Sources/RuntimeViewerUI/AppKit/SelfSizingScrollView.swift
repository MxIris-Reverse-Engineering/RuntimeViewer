#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import UIFoundation

/// Scroll view whose intrinsic content size mirrors its document view, so it
/// only grows to fit the embedded content. `minimumContentSize` keeps the view
/// from collapsing below a floor; `maximumContentSize` (or an external
/// `lessThanOrEqualTo` constraint) caps the size. Once the document exceeds
/// the cap, the built-in scrollers take over.
open class SelfSizingScrollView: ScrollView {
    @ViewInvalidating(.intrinsicContentSize)
    public var minimumContentSize = NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)

    @ViewInvalidating(.intrinsicContentSize)
    public var maximumContentSize = NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)

    open override var intrinsicContentSize: NSSize {
        guard let documentView else { return super.intrinsicContentSize }
        let documentIntrinsic = documentView.intrinsicContentSize
        return NSSize(
            width: clampedAxis(documentIntrinsic.width, minimum: minimumContentSize.width, maximum: maximumContentSize.width),
            height: clampedAxis(documentIntrinsic.height, minimum: minimumContentSize.height, maximum: maximumContentSize.height)
        )
    }

    private func clampedAxis(_ contentValue: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let hasMinimum = minimum != NSView.noIntrinsicMetric && minimum > 0
        let hasMaximum = maximum != NSView.noIntrinsicMetric && maximum > 0

        if contentValue == NSView.noIntrinsicMetric {
            return hasMinimum ? minimum : NSView.noIntrinsicMetric
        }
        var resolved = contentValue
        if hasMaximum {
            resolved = min(resolved, maximum)
        }
        if hasMinimum {
            resolved = max(resolved, minimum)
        }
        return resolved
    }
}

/// `SingleColumnTableView` variant whose intrinsic content height equals the
/// sum of its row heights. Pair with `SelfSizingScrollView` so the scroll view
/// can shrink to exactly fit the rows.
open class SelfSizingTableView: SingleColumnTableView {
    open override var intrinsicContentSize: NSSize {
        let rowCount = numberOfRows
        guard rowCount > 0 else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        var totalHeight: CGFloat = 0
        for rowIndex in 0..<rowCount {
            totalHeight += rect(ofRow: rowIndex).height
        }
        totalHeight += intercellSpacing.height * CGFloat(max(rowCount - 1, 0))
        return NSSize(width: NSView.noIntrinsicMetric, height: totalHeight)
    }

    open override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        enclosingScrollView?.invalidateIntrinsicContentSize()
    }

    open override func reloadData() {
        super.reloadData()
        invalidateIntrinsicContentSize()
    }

    open override func noteHeightOfRows(withIndexesChanged indexSet: IndexSet) {
        super.noteHeightOfRows(withIndexesChanged: indexSet)
        invalidateIntrinsicContentSize()
    }

    open override func noteNumberOfRowsChanged() {
        super.noteNumberOfRowsChanged()
        invalidateIntrinsicContentSize()
    }
}

#endif
