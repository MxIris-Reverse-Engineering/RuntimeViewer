import AppKit
import Foundation
import Testing
@testable import RuntimeViewerUI

/// The activity capsule holding the runtime source picker, as Xcode 26 holds its scheme picker: how
/// the text and the picker share the capsule, the per-activity narrowing, the widening on hover and
/// what a click hits (proposal `0070-xcode-style-runtime-source-picker`; spec in
/// `/Volumes/RE/Xcode/26.6/README.md`, "Scheme picker in the toolbar activity view"). The capsule is
/// not in a window, so nothing animates and every layout lands at once.
@Suite("Toolbar activity view with the source picker")
@MainActor
struct ToolbarActivityViewSourcePickerTests {
    private static func state(_ text: String, reportIdentifier: UUID = UUID()) -> ToolbarActivityState {
        ToolbarActivityState(
            reportIdentifier: reportIdentifier,
            isCompleted: true,
            segments: [ActivityTextSegment(text, priority: 1)],
            progress: nil,
            activityCount: 1
        )
    }

    private static let longText = "Building Searchable Interfaces for every image the engine has loaded so far"

    private static func makeCapsule(width: CGFloat, text: String = "Ready", reportIdentifier: UUID = UUID()) throws -> (ToolbarActivityView, RuntimeSourcePicker) {
        let capsule = ToolbarActivityView(showsSourcePicker: true)
        let picker = try #require(capsule.sourcePicker)
        picker.title = "My Mac (Mac Catalyst)"
        picker.icon = .image(NSImage(size: NSSize(width: 32, height: 32)))
        capsule.apply(state(text, reportIdentifier: reportIdentifier), animated: false)
        capsule.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        capsule.layoutSubtreeIfNeeded()
        return (capsule, picker)
    }

    private static func textFrame(of capsule: ToolbarActivityView) throws -> NSRect {
        capsule.statusTextFrame
    }

    private static func enterEvent() throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
    }

    @Test("with room to spare the text is right-aligned against the trailing padding and the picker shows whole")
    func wideCapsuleShowsEverything() throws {
        guard ToolbarActivityView.usesGlassToolbarMetrics else { return }
        let (capsule, picker) = try Self.makeCapsule(width: 600)
        let textFrame = try Self.textFrame(of: capsule)

        let trailingEdge: CGFloat = 600 - 12
        #expect(textFrame.maxX == trailingEdge)
        #expect(picker.frame.minX == 6)
        #expect(picker.frame.width == picker.wantedWidth)
        #expect(capsule.clampedSourcePickerWidth == nil)
    }

    @Test("a long text keeps the picker's reserve and pushes it down to the room left, no less than 56")
    func longTextNarrowsThePicker() throws {
        guard ToolbarActivityView.usesGlassToolbarMetrics else { return }
        let (capsule, picker) = try Self.makeCapsule(width: 300, text: Self.longText)
        let textFrame = try Self.textFrame(of: capsule)
        let reserve = max(56, min(picker.wantedWidth, 0.2 * 300))

        let trailingEdge: CGFloat = 300 - 12
        #expect(textFrame.maxX == trailingEdge)
        #expect(textFrame.minX >= reserve + 12 - 0.5)
        #expect(abs(picker.frame.maxX - textFrame.minX) <= 0.5)
        #expect(picker.frame.width < picker.wantedWidth)
        #expect(capsule.clampedSourcePickerWidth == picker.frame.width)
    }

    @Test("within one activity the narrowed picker does not widen again; another activity starts it over")
    func clampHoldsForTheActivity() throws {
        guard ToolbarActivityView.usesGlassToolbarMetrics else { return }
        let reportIdentifier = UUID()
        let (capsule, picker) = try Self.makeCapsule(width: 300, text: Self.longText, reportIdentifier: reportIdentifier)
        let narrowedWidth = picker.frame.width

        capsule.apply(Self.state("Done", reportIdentifier: reportIdentifier), animated: false)
        capsule.layoutSubtreeIfNeeded()
        let widthWithinTheActivity = picker.frame.width
        capsule.apply(Self.state("Done"), animated: false)
        capsule.layoutSubtreeIfNeeded()

        #expect(widthWithinTheActivity == narrowedWidth)
        #expect(picker.frame.width == picker.wantedWidth)
    }

    @Test("a pointer over a narrowed picker widens it to its wanted width; half a second after it leaves the picker narrows again")
    func hoverWidensANarrowedPicker() async throws {
        guard ToolbarActivityView.usesGlassToolbarMetrics else { return }
        let (capsule, picker) = try Self.makeCapsule(width: 300, text: Self.longText)
        let narrowedWidth = picker.frame.width

        picker.mouseEntered(with: try Self.enterEvent())
        capsule.layoutSubtreeIfNeeded()
        let hoveredWidth = picker.frame.width
        let hoveredTextFrame = try Self.textFrame(of: capsule)
        picker.mouseExited(with: try Self.enterEvent())
        let stateRightAfterLeaving = capsule.sourcePickerHoverState
        try await Task.sleep(for: .milliseconds(800))
        capsule.layoutSubtreeIfNeeded()

        #expect(hoveredWidth == picker.wantedWidth)
        #expect(hoveredTextFrame.minX >= picker.wantedWidth + 12 - 0.5)
        #expect(stateRightAfterLeaving == .hovered(targetWidth: picker.wantedWidth))
        #expect(capsule.sourcePickerHoverState == .notHovered)
        #expect(picker.frame.width == narrowedWidth)
    }

    @Test("a pointer over a picker already whole holds its width without widening")
    func hoverOverAWholePickerHoldsIt() throws {
        let (capsule, picker) = try Self.makeCapsule(width: 600)

        picker.mouseEntered(with: try Self.enterEvent())

        #expect(capsule.sourcePickerHoverState == .hoveredWithoutResize)
    }

    @Test("while the popover shows the picker stays put; closing it with the pointer away narrows the picker at once")
    func popoverHoldsThePicker() throws {
        guard ToolbarActivityView.usesGlassToolbarMetrics else { return }
        let (capsule, picker) = try Self.makeCapsule(width: 300, text: Self.longText)
        picker.mouseEntered(with: try Self.enterEvent())
        capsule.layoutSubtreeIfNeeded()
        let widenedFrame = picker.frame

        picker.isShowingPopover = true
        picker.mouseExited(with: try Self.enterEvent())
        capsule.apply(Self.state(Self.longText + " and then some"), animated: false)
        capsule.layoutSubtreeIfNeeded()
        let frameWhilePopoverShows = picker.frame
        let stateWhilePopoverShows = capsule.sourcePickerHoverState
        picker.isShowingPopover = false

        #expect(frameWhilePopoverShows == widenedFrame)
        #expect(stateWhilePopoverShows == .hovered(targetWidth: picker.wantedWidth))
        #expect(capsule.sourcePickerHoverState == .notHovered)
    }

    @Test("a click on the picker goes to the picker, a click anywhere else to the capsule")
    func clicksReachThePickerOrTheCapsule() throws {
        let (capsule, picker) = try Self.makeCapsule(width: 600)
        let textFrame = try Self.textFrame(of: capsule)

        #expect(capsule.hitTest(NSPoint(x: picker.frame.midX, y: picker.frame.midY)) === picker)
        #expect(capsule.hitTest(NSPoint(x: textFrame.midX, y: textFrame.midY)) === capsule)
    }
}
