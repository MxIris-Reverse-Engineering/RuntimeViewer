import AppKit
import Foundation
import Testing
import RuntimeViewerUI

/// Regression suite for a long toolbar title pushing the items after it into the overflow menu.
///
/// History: NSToolbar works out an item's minimum width by pulling the item's view to zero width
/// at priority 200, and decides which items go into the overflow menu from those minimums alone.
/// The labels of `TitleToolbarItem` resisted compression at `.defaultLow` (250), so their whole
/// text became the item's minimum width: a long title or subtitle in the main window moved the
/// source picker and every button after it into the overflow menu. Making the labels give way
/// below 200 was not enough on its own — the item then measured zero points wide, which the toolbar
/// answers by laying it out zero points wide, and its text stack squeezed the wider label down to
/// the narrower one. Background:
/// `Documentations/ResolvedIssues/2026-10-02-long-toolbar-title-pushed-items-into-overflow.md`.
///
/// The fixture is shaped like the main window's toolbar: the title item, a flexible space, then a
/// row of buttons, in a unified toolbar. Whether a label is cut short is read off the label itself —
/// its frame against its intrinsic width — rather than off a measurement of the item, which the
/// squeezing above got wrong too.
@Suite("TitleToolbarItemOverflow", .serialized)
@MainActor
struct TitleToolbarItemOverflowTests {
    /// Which of the two labels carries the text wider than the window.
    enum LongLabel: CaseIterable, Sendable {
        case title
        case subtitle
    }

    private static let textWiderThanTheWindow = String(repeating: "NSToolbarItemViewerOverflowFix ", count: 12)

    private static func texts(withLong longLabel: LongLabel) -> (title: String, subtitle: String) {
        (
            title: longLabel == .title ? textWiderThanTheWindow : "AppKit",
            subtitle: longLabel == .subtitle ? textWiderThanTheWindow : "NSControl"
        )
    }

    @Test("a long title or subtitle leaves every button on the toolbar", arguments: LongLabel.allCases)
    func longLabelLeavesEveryButtonOnTheToolbar(longLabel: LongLabel) {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        let texts = Self.texts(withLong: longLabel)
        fixture.show(title: texts.title, subtitle: texts.subtitle)

        let overflowedIdentifiers = fixture.buttonIdentifiersInTheOverflowMenu()
        #expect(overflowedIdentifiers.isEmpty, "in the overflow menu instead of on the toolbar: \(overflowedIdentifiers)")
    }

    @Test("a long title or subtitle takes the room the buttons leave and is cut short there", arguments: LongLabel.allCases)
    func longLabelFillsTheRoomTheButtonsLeave(longLabel: LongLabel) throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        let texts = Self.texts(withLong: longLabel)
        fixture.show(title: texts.title, subtitle: texts.subtitle)

        let longTextLabel = try #require(fixture.shownTitleLabels().first { $0.stringValue == Self.textWiderThanTheWindow })
        #expect(
            longTextLabel.frame.width < longTextLabel.intrinsicContentSize.width,
            "not cut short: \(longTextLabel.frame.width) pt shown of \(longTextLabel.intrinsicContentSize.width) pt"
        )
        // Measured: 12 pt of item spacing when the title takes the room, over 400 pt when it
        // stops short of it.
        let gap = try #require(fixture.gapBetweenTitleAndFirstButton())
        #expect(gap < 40, "\(gap) pt left empty between the cut-short title and the first button")
    }

    @Test("a title that fits is shown at its full width and no wider")
    func fittingTitleTakesItsTextWidth() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.show(title: "AppKit", subtitle: "NSControl")

        let shownLabels = fixture.shownTitleLabels()
        let cutShortLabels = shownLabels.filter { label in
            label.frame.width < label.intrinsicContentSize.width - 0.5
        }
        #expect(
            cutShortLabels.isEmpty,
            "cut short: \(cutShortLabels.map { "\($0.stringValue) \($0.frame.width) of \($0.intrinsicContentSize.width) pt" })"
        )
        // The room the title does not need stays with the flexible space after it. Without the
        // item's maximum width the title stretched over all of it: 467 pt for 54 pt of text.
        let textWidth = try #require(shownLabels.map(\.intrinsicContentSize.width).max())
        let insets = fixture.titleItem.insets
        let titleWidth = try #require(fixture.titleItem.view).frame.width
        #expect(
            titleWidth <= insets.left + textWidth + insets.right + 0.5,
            "the title is \(titleWidth) pt wide for \(textWidth) pt of text"
        )
    }
}

// MARK: - Fixture

extension TitleToolbarItemOverflowTests {
    /// The title item, a flexible space and six buttons in an 800-point window outside every
    /// display: room for every button and a short title, not for text wider than the window.
    @MainActor
    final class Fixture: NSObject, NSToolbarDelegate {
        static let titleItemIdentifier = NSToolbarItem.Identifier("title")

        static let buttonItemIdentifiers = (1 ... 6).map { NSToolbarItem.Identifier("button\($0)") }

        let window: NSWindow
        let toolbar = NSToolbar()
        let titleItem = TitleToolbarItem(itemIdentifier: Fixture.titleItemIdentifier)

        override init() {
            window = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: 800, height: 400),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            super.init()

            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false

            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.toolbar = toolbar
            window.orderFrontRegardless()
            layOut()
        }

        func tearDown() {
            window.orderOut(nil)
        }

        func show(title: String, subtitle: String) {
            titleItem.displayTitle = title
            titleItem.displaySubtitle = subtitle
            layOut()
        }

        /// What the window does at the end of a run loop turn.
        func layOut() {
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }

        /// The buttons the toolbar does not show, in toolbar order.
        func buttonIdentifiersInTheOverflowMenu() -> [String] {
            let visibleIdentifiers = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
            return Self.buttonItemIdentifiers
                .filter { identifier in !visibleIdentifiers.contains(identifier) }
                .map(\.rawValue)
        }

        /// The labels the title item has on screen, as laid out.
        func shownTitleLabels() -> [NSTextField] {
            guard let titleView = titleItem.view else { return [] }
            return Self.descendants(of: titleView)
                .compactMap { $0 as? NSTextField }
                .filter { label in !label.isHiddenOrHasHiddenAncestor }
        }

        /// The empty width between the title item's view and the first button, in window
        /// coordinates; `nil` when either of them is not in the window.
        func gapBetweenTitleAndFirstButton() -> CGFloat? {
            guard let titleView = titleItem.view, titleView.window === window,
                  let firstButton = toolbar.items.first(where: { $0.itemIdentifier == Self.buttonItemIdentifiers[0] })?.view,
                  firstButton.window === window
            else { return nil }
            let titleFrame = titleView.convert(titleView.bounds, to: nil)
            let firstButtonFrame = firstButton.convert(firstButton.bounds, to: nil)
            return firstButtonFrame.minX - titleFrame.maxX
        }

        private static func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { subview in [subview] + descendants(of: subview) }
        }

        // MARK: - NSToolbarDelegate

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [Self.titleItemIdentifier, .flexibleSpace] + Self.buttonItemIdentifiers
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            if itemIdentifier == Self.titleItemIdentifier {
                return titleItem
            }
            let buttonItem = NSToolbarItem(itemIdentifier: itemIdentifier)
            buttonItem.label = itemIdentifier.rawValue
            let button = NSButton(title: "", target: nil, action: nil)
            button.image = NSImage(systemSymbolName: "square", accessibilityDescription: nil)
            button.bezelStyle = .toolbar
            buttonItem.view = button
            return buttonItem
        }
    }
}
