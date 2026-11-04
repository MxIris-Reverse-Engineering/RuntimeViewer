#if os(macOS)

import AppKit

/// The document icon of Xcode 27's window title, for symbols of our own: one glyph in one flat
/// colour, with no plate behind it.
///
/// Xcode's project icon is the custom symbol `doc-project` in system blue, drawn by `IconView` at
/// 13 points, medium weight, large scale: the glyph is drawn into a transparent layer and filled
/// with the colour by source-in compositing, its alignment rectangle centred in the 18-point slot
/// on whole pixels (DVTUserInterfaceKit 27.2 27B52, 0xB45D8 and 0xB44DC). The rounded square the
/// progress ring collapses into is the ring's own shape, which clears as the icon fades in. Spec:
/// `/Volumes/RE/Xcode/27.2-27B52/README.md`, "The project icon in the window title".
///
/// A glyph larger than the slot overhangs it, as Xcode's own frame does: `doc-project` is about
/// 19.5 points at this size, measured off Xcode's title. So the image is the slot grown evenly
/// around its centre until the whole glyph fits, and the title draws it at its own size, centred on
/// the slot. Cutting it to the slot took the outer half of a frame's stroke off.
public enum TitleDocumentIcon {
    /// `NSImageSymbolConfiguration(pointSize: 13, weight: .medium, scale: .large)`.
    public static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium, scale: .large)

    /// The slot the glyph's alignment rectangle is centred in. The image is at least this size.
    public static let slotSize = NSSize(width: TitleActivityIndicatorView.slotSize, height: TitleActivityIndicatorView.slotSize)

    /// `symbol` at the title's size, filled with `color`, its alignment rectangle at the image's
    /// centre — the slot's. The image draws itself for the appearance it is drawn in, so a dynamic
    /// colour follows it.
    public static func image(symbol: NSImage, color: NSColor) -> NSImage {
        let configuredSymbol = symbol.withSymbolConfiguration(symbolConfiguration) ?? symbol
        let alignmentRect = configuredSymbol.alignmentRect
        let symbolSize = configuredSymbol.size
        // Where the glyph's image goes from the centre: its alignment rectangle in the middle.
        let offset = CGPoint(x: -alignmentRect.width / 2 - alignmentRect.minX, y: -alignmentRect.height / 2 - alignmentRect.minY)
        // Whole points either side of the centre, so that the centre stays on the pixel grid.
        let halfWidth = max(slotSize.width / 2, -offset.x, offset.x + symbolSize.width).rounded(.up)
        let halfHeight = max(slotSize.height / 2, -offset.y, offset.y + symbolSize.height).rounded(.up)
        let image = NSImage(size: NSSize(width: halfWidth * 2, height: halfHeight * 2), flipped: false) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            let backingScale = context.cgContext.userSpaceToDeviceSpaceTransform.a
            let pixelScale = backingScale > 0 ? backingScale : 1
            func pixelAligned(_ value: CGFloat) -> CGFloat {
                (value * pixelScale).rounded() / pixelScale
            }
            // The alignment rectangle in the middle, then the whole image placed around it.
            let origin = CGPoint(x: pixelAligned(rect.midX + offset.x), y: pixelAligned(rect.midY + offset.y))
            context.saveGraphicsState()
            // A layer of its own, so the source-in fill colours the glyph and nothing under it.
            context.cgContext.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
            configuredSymbol.draw(in: CGRect(origin: origin, size: symbolSize), from: .zero, operation: .sourceOver, fraction: 1)
            color.setFill()
            rect.fill(using: .sourceIn)
            context.cgContext.endTransparencyLayer()
            context.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        return image
    }
}

#endif
