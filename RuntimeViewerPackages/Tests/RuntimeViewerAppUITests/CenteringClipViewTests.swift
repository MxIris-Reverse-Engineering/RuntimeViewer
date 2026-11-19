#if os(macOS)

import AppKit
import Testing
@testable import RuntimeViewerUI

/// `CenteringClipView`: a document smaller than the clip view sits in the
/// middle of it instead of in the top-left corner; a larger one scrolls and
/// clamps as `NSClipView` makes it.
@MainActor
@Suite("CenteringClipView")
struct CenteringClipViewTests {
    private static let visibleRectAtOrigin = NSRect(x: 0, y: 0, width: 400, height: 300)

    private static func makeClipView(documentSize: CGSize, centering: Bool = true) -> NSClipView {
        let scrollView = NSScrollView(frame: visibleRectAtOrigin)
        let clipView = centering ? CenteringClipView() : NSClipView()
        scrollView.contentView = clipView
        scrollView.documentView = NSView(frame: NSRect(origin: .zero, size: documentSize))
        return clipView
    }

    @Test("a document smaller than the clip view is centred along both axes")
    func smallerDocumentIsCentered() {
        let clipView = Self.makeClipView(documentSize: CGSize(width: 200, height: 100))

        let bounds = clipView.constrainBoundsRect(Self.visibleRectAtOrigin)

        #expect(bounds.origin == CGPoint(x: -100, y: -100))
        #expect(bounds.size == Self.visibleRectAtOrigin.size)
    }

    @Test("a document smaller along one axis is centred along it and scrolls along the other")
    func documentSmallerAlongOneAxis() {
        let clipView = Self.makeClipView(documentSize: CGSize(width: 1000, height: 100))

        let bounds = clipView.constrainBoundsRect(NSRect(x: 250, y: 40, width: 400, height: 300))

        #expect(bounds.origin == CGPoint(x: 250, y: -100))
    }

    @Test("a document larger than the clip view is clamped exactly as NSClipView clamps it")
    func largerDocumentIsClampedAsBefore() {
        let documentSize = CGSize(width: 1000, height: 800)
        let centeringClipView = Self.makeClipView(documentSize: documentSize)
        let plainClipView = Self.makeClipView(documentSize: documentSize, centering: false)

        for proposedOrigin in [CGPoint(x: -50, y: 900), CGPoint(x: 300, y: 200), CGPoint(x: 900, y: -20)] {
            let proposedBounds = NSRect(origin: proposedOrigin, size: Self.visibleRectAtOrigin.size)
            #expect(centeringClipView.constrainBoundsRect(proposedBounds) == plainClipView.constrainBoundsRect(proposedBounds))
        }
    }
}

#endif
