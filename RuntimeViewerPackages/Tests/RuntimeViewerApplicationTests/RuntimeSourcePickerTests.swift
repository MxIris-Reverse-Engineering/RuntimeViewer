import AppKit
import Testing
@testable import RuntimeViewerUI

/// The toolbar's runtime source picker in both of Xcode's styles: the width it wants, where its
/// title goes and when it fades, its highlight, the toolbar view that holds it in Xcode 27's style,
/// and what it tells accessibility (proposal `draft-xcode-style-runtime-source-picker`; specs in
/// `/Volumes/RE/Xcode/26.6/README.md` and `/Volumes/RE/Xcode/27.2-27B52/README.md`).
///
/// The press itself is not driven here: the picker sends its action through `NSApp`, which a
/// `swift test` process does not have.
@Suite("Runtime source picker")
@MainActor
struct RuntimeSourcePickerTests {
    private static func makePicker(style: RuntimeSourcePicker.Style, title: String = "My Mac", hasImage: Bool = true) -> RuntimeSourcePicker {
        let picker = RuntimeSourcePicker(style: style)
        picker.title = title
        picker.image = hasImage ? NSImage(size: NSSize(width: 32, height: 32)) : nil
        return picker
    }

    private static func titleWidth(_ title: String, fontSize: CGFloat) -> CGFloat {
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: fontSize)]).size().width
    }

    @Test("In Xcode 27's style the picker wants 6 + 18-point icon + 4 + title + 6, plus DVTKit's 2")
    func toolbarStyleWantsItsContentWidth() {
        let picker = Self.makePicker(style: .toolbar)
        let titleWidth = Self.titleWidth("My Mac", fontSize: NSFont.systemFontSize(for: .large))

        #expect(abs(picker.componentWidth - (6 + 18 + 4 + titleWidth + 6)) < 0.001)
        #expect(abs(picker.wantedWidth - (picker.componentWidth + 2)) < 0.001)
        #expect(picker.intrinsicContentSize.height == 28)
    }

    @Test("In Xcode 26's capsule on the macOS 26 design the picker wants 43 points more than its 11-point title")
    func activityViewStyleWantsItsContentWidth() {
        guard ToolbarActivityView.usesGlassToolbarMetrics else { return }
        let picker = Self.makePicker(style: .activityView)
        let titleWidth = Self.titleWidth("My Mac", fontSize: NSFont.systemFontSize(for: .small))

        #expect(abs(picker.componentWidth - (titleWidth + 41)) < 0.001)
        #expect(abs(picker.wantedWidth - (titleWidth + 43)) < 0.001)
        #expect(picker.intrinsicContentSize.height == 24)
    }

    @Test("Without an icon the title starts at the leading inset, with no icon spacing")
    func titleStartsAtTheLeadingInsetWithoutAnIcon() throws {
        let picker = Self.makePicker(style: .toolbar, hasImage: false)
        picker.frame = NSRect(x: 0, y: 0, width: picker.wantedWidth, height: 28)

        let layout = try #require(picker.titleLayout(forWidth: picker.bounds.width))
        #expect(layout.rect.minX == 6)
        #expect(layout.fades == false)
    }

    @Test("A title wider than its room by more than 0.9 points fades out; by less it is only clipped")
    func titleFadesOnlyPastTheThreshold() throws {
        let picker = Self.makePicker(style: .toolbar, title: "RuntimeViewer macOS")
        let wholeWidth = picker.componentWidth
        // The title's room is the width less the text offset and the trailing inset, plus 2.
        let barelyShortWidth = wholeWidth - 2 - 0.5
        let shortWidth = wholeWidth - 2 - 5

        let barelyShortLayout = try #require(picker.titleLayout(forWidth: barelyShortWidth))
        let shortLayout = try #require(picker.titleLayout(forWidth: shortWidth))
        let wholeLayout = try #require(picker.titleLayout(forWidth: wholeWidth))

        #expect(barelyShortLayout.fades == false)
        #expect(shortLayout.fades)
        #expect(wholeLayout.fades == false)
        let titleOffset: CGFloat = 6 + 18 + 4
        #expect(shortLayout.rect.minX == titleOffset)
    }

    @Test("No title is drawn once the component has 3 points or less for it")
    func noTitleWithoutRoom() {
        let picker = Self.makePicker(style: .toolbar)

        #expect(picker.titleLayout(forWidth: 6 + 18 + 4 + 6 + 3) == nil)
        #expect(picker.titleLayout(forWidth: 6 + 18 + 4 + 6 + 4) != nil)
    }

    @Test("The highlight shows while the pointer is over the picker and while its popover shows, and the owner hears of each")
    func highlightFollowsHoverAndPopover() throws {
        let picker = Self.makePicker(style: .toolbar)
        var changes: [RuntimeSourcePicker.Change] = []
        picker.changeHandler = { changes.append($0) }
        let event = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))

        picker.mouseEntered(with: event)
        let drawsWhileHovered = picker.drawsHighlight
        picker.mouseExited(with: event)
        let drawsAfterLeaving = picker.drawsHighlight
        picker.isShowingPopover = true
        let drawsWhilePopoverShows = picker.drawsHighlight
        picker.isShowingPopover = false

        #expect(drawsWhileHovered)
        #expect(drawsAfterLeaving == false)
        #expect(drawsWhilePopoverShows)
        #expect(picker.drawsHighlight == false)
        #expect(changes == [.hover, .hover, .popover, .popover])
    }

    @Test("In Xcode 27's style the highlight is a capsule as tall as the picker, across its whole width")
    func toolbarHighlightCoversThePicker() {
        let picker = Self.makePicker(style: .toolbar)
        picker.frame = NSRect(x: 0, y: 0, width: 120, height: 28)

        #expect(picker.highlightRect == NSRect(x: 0, y: 0, width: 120, height: 28))
        #expect(picker.metrics.drawsCapsuleHighlight)
        #expect(picker.metrics.showsHoverChevron == false)
    }

    @Test("A new title or icon changes the width the picker wants, and tells its owner")
    func titleChangeReportsAWantedWidthChange() {
        let picker = Self.makePicker(style: .toolbar)
        var changes: [RuntimeSourcePicker.Change] = []
        picker.changeHandler = { changes.append($0) }
        let widthBefore = picker.wantedWidth

        picker.title = "My Mac (Mac Catalyst)"
        picker.title = "My Mac (Mac Catalyst)"
        picker.image = nil

        let titleWidth = Self.titleWidth("My Mac (Mac Catalyst)", fontSize: NSFont.systemFontSize(for: .large))
        #expect(abs(picker.wantedWidth - (6 + titleWidth + 6 + 2)) < 0.001)
        #expect(picker.wantedWidth != widthBefore)
        #expect(changes == [.wantedWidth, .wantedWidth])
    }

    @Test("Accessibility sees a pop-up button named Runtime Source, valued with the title")
    func accessibilitySeesAPopUpButton() {
        let picker = Self.makePicker(style: .activityView, title: "iPhone")

        #expect(picker.isAccessibilityElement())
        #expect(picker.accessibilityRole() == .popUpButton)
        #expect(picker.accessibilityLabel() == "Runtime Source")
        #expect(picker.accessibilityValue() as? String == "iPhone")
    }

    @Test("The toolbar view is 28 tall, at least 87 wide, at most the picker's wanted width plus 8, and holds the picker 4 in")
    func toolbarViewSizesLikeXcode() throws {
        let toolbarView = RuntimeSourcePickerToolbarView()
        toolbarView.picker.title = "RuntimeViewer macOS"
        toolbarView.picker.image = NSImage(size: NSSize(width: 32, height: 32))
        let expectedMaximumWidth = max(toolbarView.picker.wantedWidth + 8, 87)

        let maximumWidthConstraint = try #require(toolbarView.constraints.first { $0.firstAttribute == .width && $0.relation == .lessThanOrEqual })
        let minimumWidthConstraint = try #require(toolbarView.constraints.first { $0.firstAttribute == .width && $0.relation == .greaterThanOrEqual })
        let heightConstraint = try #require(toolbarView.constraints.first { $0.firstAttribute == .height })
        #expect(maximumWidthConstraint.constant == expectedMaximumWidth)
        #expect(minimumWidthConstraint.constant == 87)
        #expect(heightConstraint.constant == 28)
        #expect([maximumWidthConstraint, minimumWidthConstraint, heightConstraint].allSatisfy { $0.priority.rawValue == 999 })

        // Laid out on its own, the view takes the width its constraints allow: the maximum.
        toolbarView.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        toolbarView.layoutSubtreeIfNeeded()
        #expect(abs(toolbarView.bounds.width - expectedMaximumWidth) <= 0.5)
        #expect(toolbarView.picker.frame == NSRect(x: 4, y: 0, width: toolbarView.bounds.width - 8, height: 28))
    }

    @Test("A short title still leaves the toolbar view its 87-point minimum as its maximum")
    func toolbarViewNeverNarrowerThanItsMinimum() {
        let toolbarView = RuntimeSourcePickerToolbarView()
        toolbarView.picker.title = "Mac"

        #expect(toolbarView.maximumWidth == 87)
    }
}
