import AppKit
import Foundation
import Testing
@testable import RuntimeViewerUI

/// The window title's activity display from macOS 27 — Xcode 27's ring in place of the document's
/// icon: the shape at the stages of a run's end, how a report's progress becomes the ring, and the
/// subtitle that shows the activity while the pointer is over the title (proposal
/// `draft-xcode-activity-progress`; spec in `/Volumes/RE/Xcode/27.2-27B52/README.md`).
@Suite("Title activity indicator")
@MainActor
struct TitleActivityIndicatorTests {
    /// The 20-point ring, a seventh of it thick, with y pointing down as the shape is worked out.
    private static let ringRect = CGRect(x: 0, y: 0, width: 20, height: 20)

    private static let thickness: CGFloat = 20.0 / 7

    private static func shape(progress: CGFloat, centerCollapseProgress: CGFloat = 0, squareRevealProgress: CGFloat = 0) -> CGPath {
        CollapsibleProgressLayer.path(
            in: ringRect,
            progress: progress,
            thickness: thickness,
            centerCollapseProgress: centerCollapseProgress,
            squareRevealProgress: squareRevealProgress,
            squareCornerRadiusPercent: 0.26
        )
    }

    @Test("Half a run is the right half of the ring, from twelve o'clock clockwise")
    func halfRunCoversTheRightHalf() {
        let path = Self.shape(progress: 0.5)

        #expect(path.contains(CGPoint(x: 19, y: 10)))
        #expect(path.contains(CGPoint(x: 1, y: 10)) == false)
        #expect(path.contains(CGPoint(x: 10, y: 10)) == false)
    }

    @Test("The centre closes as the run's end collapses it")
    func collapsedCenterIsSolid() {
        #expect(Self.shape(progress: 1).contains(CGPoint(x: 10, y: 10)) == false)
        #expect(Self.shape(progress: 1, centerCollapseProgress: 1).contains(CGPoint(x: 10, y: 10)))
    }

    @Test("The rounded square's corners grow out of the circle")
    func revealedSquareFillsTheCorners() {
        // Outside the circle, inside a square rounded at 5.2 points.
        let cornerPoint = CGPoint(x: 2.5, y: 2.5)

        #expect(Self.shape(progress: 1, centerCollapseProgress: 1).contains(cornerPoint) == false)
        #expect(Self.shape(progress: 1, centerCollapseProgress: 1, squareRevealProgress: 1).contains(cornerPoint))
    }

    @Test("The arc shows from 5 % for a run just started, stops at 82 % until the run is done, and is a third while unknown", arguments: [
        (fraction: 0.0 as Double?, visual: 0.05 as CGFloat),
        (fraction: 0.5, visual: 0.435),
        (fraction: 1.0, visual: 1.0),
        (fraction: nil, visual: 0.33),
    ])
    func visualProgress(fraction: Double?, visual: CGFloat) {
        #expect(abs(TitleActivityIndicatorView.visualProgress(for: fraction) - visual) < 0.000001)
    }

    @Test("Nothing running, a finished run and a run at 0 show the icon; an unknown progress spins")
    func fractionForStates() {
        let reportIdentifier = UUID()
        func state(progress: ToolbarActivityState.Progress?, isCompleted: Bool = false, reportIdentifier: UUID? = reportIdentifier) -> ToolbarActivityState {
            ToolbarActivityState(reportIdentifier: reportIdentifier, isCompleted: isCompleted, segments: [], progress: progress, activityCount: 1)
        }

        #expect(TitleActivityIndicatorView.fractionCompleted(for: state(progress: nil, reportIdentifier: nil)) == 1)
        #expect(TitleActivityIndicatorView.fractionCompleted(for: state(progress: nil, isCompleted: true)) == 1)
        #expect(TitleActivityIndicatorView.fractionCompleted(for: state(progress: .determinate(percent: 0))) == 1)
        #expect(TitleActivityIndicatorView.fractionCompleted(for: state(progress: .determinate(percent: 37))) == 0.37)
        #expect(TitleActivityIndicatorView.fractionCompleted(for: state(progress: .indeterminate)) == nil)
    }

    @Test("The title's icon is one glyph in one flat colour, with nothing behind it")
    func documentIconIsOneFlatColour() throws {
        let symbol = try #require(NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil))
        let icon = TitleDocumentIcon.image(symbol: symbol, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = TitleDocumentIcon.canvasSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(origin: .zero, size: TitleDocumentIcon.canvasSize))
        NSGraphicsContext.restoreGraphicsState()

        var opaquePixelCount = 0
        var offColourPixelCount = 0
        for x in 0..<36 {
            for y in 0..<36 {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), colour.alphaComponent > 0.99 else { continue }
                opaquePixelCount += 1
                if colour.redComponent < 0.95 || colour.greenComponent > 0.05 || colour.blueComponent > 0.05 {
                    offColourPixelCount += 1
                }
            }
        }
        #expect(opaquePixelCount > 0)
        #expect(offColourPixelCount == 0)
    }

    @Test("While the pointer is over the title the subtitle shows the activity, and its own subtitle again after")
    func subtitleShowsActivityWhilePointerInside() throws {
        let titleItem = TitleToolbarItem(itemIdentifier: NSToolbarItem.Identifier("title"), showsActivity: true)
        titleItem.displayTitle = "AppKit"
        titleItem.displaySubtitle = "NSView"
        titleItem.applyActivity(
            ToolbarActivityState(
                reportIdentifier: UUID(),
                isCompleted: false,
                segments: [
                    ActivityTextSegment("Indexing", priority: 2, separator: .primary),
                    ActivityTextSegment("12 of 48 images", priority: 1),
                ],
                progress: .determinate(percent: 25),
                activityCount: 1
            ),
            animated: false
        )
        let itemView = try #require(titleItem.view)
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))

        let subtitleBefore = titleItem.shownSubtitle
        itemView.mouseEntered(with: event)
        let subtitleWhileInside = titleItem.shownSubtitle
        itemView.mouseExited(with: event)
        let subtitleAfter = titleItem.shownSubtitle

        #expect(subtitleBefore == "NSView")
        #expect(subtitleWhileInside == "Indexing \u{2022} 12 of 48 images")
        #expect(subtitleAfter == "NSView")
    }
}
