#if os(macOS)

import AppKit

/// The colour an image is drawn in, read back off a bitmap, and colours compared as an appearance
/// resolves them — for the icons that are coloured by what they stand for, such as an image's kind.
package enum ImageColorSampling {
    /// Within this much of each other on every sRGB component, a drawn colour counts as the one
    /// expected: the edges of a glyph blend into the clear background, and a palette may be drawn a
    /// shade off.
    package static let drawingTolerance = 0.08

    /// The average colour of the most opaque part of `image` drawn at 16 points on a 2x bitmap in
    /// `appearance` — the pixels within a tenth of the strongest one's alpha, so that a glyph in a
    /// translucent colour such as the secondary label colour is read as well — or `nil` when nothing
    /// is drawn. Only the colour is averaged, not its opacity.
    package static func drawnColor(of image: NSImage, in appearance: NSAppearance.Name = .aqua) -> NSColor? {
        let pixelSize = 32
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = NSSize(width: 16, height: 16)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
            NSGraphicsContext.restoreGraphicsState()
        }
        let pixelColors = (0 ..< pixelSize).flatMap { row in
            (0 ..< pixelSize).compactMap { column in bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) }
        }
        guard let strongestAlpha = pixelColors.map(\.alphaComponent).max(), strongestAlpha > 0 else { return nil }
        let strongestPixelColors = pixelColors.filter { $0.alphaComponent > strongestAlpha * 0.9 }
        let pixelCount = CGFloat(strongestPixelColors.count)
        return NSColor(
            srgbRed: strongestPixelColors.map(\.redComponent).reduce(0, +) / pixelCount,
            green: strongestPixelColors.map(\.greenComponent).reduce(0, +) / pixelCount,
            blue: strongestPixelColors.map(\.blueComponent).reduce(0, +) / pixelCount,
            alpha: 1
        )
    }

    /// Whether `image` is drawn in `expectedColor`, both as `appearance` resolves them.
    package static func isDrawn(_ image: NSImage?, in expectedColor: NSColor, appearance: NSAppearance.Name = .aqua) -> Bool {
        guard let image, let drawnColor = drawnColor(of: image, in: appearance) else { return false }
        return isSameColor(drawnColor, expectedColor, in: appearance, tolerance: drawingTolerance)
    }

    /// Whether `color` and `otherColor` are the same colour as `appearance` resolves them, within
    /// `tolerance` on every sRGB component — by default, less than one step of an 8-bit component.
    package static func isSameColor(_ color: NSColor, _ otherColor: NSColor, in appearance: NSAppearance.Name = .aqua, tolerance: Double = 0.5 / 255) -> Bool {
        guard let resolvedColor = sRGBColor(color, in: appearance),
              let otherResolvedColor = sRGBColor(otherColor, in: appearance) else { return false }
        return abs(resolvedColor.redComponent - otherResolvedColor.redComponent) < tolerance
            && abs(resolvedColor.greenComponent - otherResolvedColor.greenComponent) < tolerance
            && abs(resolvedColor.blueComponent - otherResolvedColor.blueComponent) < tolerance
    }

    /// `color` in sRGB as `appearance` resolves a dynamic colour.
    private static func sRGBColor(_ color: NSColor, in appearance: NSAppearance.Name) -> NSColor? {
        var resolvedColor: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(.sRGB)
        }
        return resolvedColor
    }
}

#endif
