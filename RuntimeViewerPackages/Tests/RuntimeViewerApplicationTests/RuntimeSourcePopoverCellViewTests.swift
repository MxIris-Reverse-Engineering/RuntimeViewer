import AppKit
import Testing
@testable import RuntimeViewerUI

/// A row of the runtime source picker's popover: Xcode 27.2's `ActivityViewPopoverTableCellView` —
/// where the checkmark, the icon and the title go, and how the filter's match shows (proposal
/// `0070-xcode-style-runtime-source-picker`; spec in `/Volumes/RE/Xcode/27.2-27B52/README.md`, "The
/// scheme picker's popover", §3).
@Suite("RuntimeSourcePopoverCellView")
@MainActor
struct RuntimeSourcePopoverCellViewTests {
    private static func makeCellView(isChecked: Bool = true) -> RuntimeSourcePopoverCellView {
        let cellView = RuntimeSourcePopoverCellView()
        cellView.title = "My Mac"
        cellView.icon = NSImage(size: NSSize(width: 32, height: 32))
        cellView.isChecked = isChecked
        cellView.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        cellView.layoutSubtreeIfNeeded()
        return cellView
    }

    @Test("from the cell's leading edge: the checkmark in 0–12, the icon in 14–30, the title from 36, all centred")
    func layoutFollowsXcode() {
        let cellView = Self.makeCellView()

        #expect(cellView.checkmarkFrame == NSRect(x: 0, y: 6, width: 12, height: 12))
        #expect(cellView.iconFrame == NSRect(x: 14, y: 4, width: 16, height: 16))
        #expect(cellView.titleFrame.minX == 36)
        #expect(abs(cellView.titleFrame.midY - 12) <= 0.5)
    }

    @Test("a row that is not checked keeps the checkmark's column, so its icon lines up with the others")
    func uncheckedRowKeepsTheColumn() {
        let cellView = Self.makeCellView(isChecked: false)

        #expect(cellView.iconFrame.minX == 14)
        #expect(cellView.titleFrame.minX == 36)
    }

    @Test("while filtering, matched characters are bold in the text colour and the rest in the secondary label colour")
    func filterMatchIsBold() throws {
        let cellView = Self.makeCellView()
        cellView.filterMatchRanges = [NSRange(location: 3, length: 3)]
        let title = cellView.displayedTitle

        let matchedFont = try #require(title.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
        let otherFont = try #require(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(matchedFont.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(otherFont.fontDescriptor.symbolicTraits.contains(.bold) == false)
        #expect(title.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor == .textColor)
        #expect(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
    }

    @Test("on a selected row the match turns to the selected text colour and the rest to it at three quarters")
    func filterMatchOnASelectedRow() throws {
        let cellView = Self.makeCellView()
        cellView.filterMatchRanges = [NSRange(location: 3, length: 3)]
        cellView.backgroundStyle = .emphasized
        let title = cellView.displayedTitle

        let matchedColor = try #require(title.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor)
        let otherColor = try #require(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(matchedColor == .alternateSelectedControlTextColor)
        let otherAlpha = try #require(otherColor.usingColorSpace(.sRGB)?.alphaComponent)
        let selectedTextAlpha = try #require(NSColor.alternateSelectedControlTextColor.usingColorSpace(.sRGB)?.alphaComponent)
        #expect(abs(otherAlpha - selectedTextAlpha * 0.75) < 0.01)
    }

    @Test("without a filter the title is plain, and a disabled row's is in the secondary label colour")
    func plainTitleAndDisabledRow() {
        let cellView = Self.makeCellView()
        let enabledTitle = cellView.displayedTitle
        cellView.isEnabled = false
        let disabledColor = cellView.displayedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor

        #expect(enabledTitle.string == "My Mac")
        #expect(enabledTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .labelColor)
        #expect(disabledColor == .secondaryLabelColor)
    }
}
