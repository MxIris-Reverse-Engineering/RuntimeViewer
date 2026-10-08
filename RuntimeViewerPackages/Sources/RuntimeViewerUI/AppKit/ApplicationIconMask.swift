#if os(macOS)

import AppKit
import QuartzCore

/// Cuts a square application icon to the rounded shape iOS draws it in.
///
/// The icon files inside an iOS application bundle are **square and fully
/// opaque** — measured, every pixel of one: the rounded shape a device shows is
/// a mask the system applies at display time, not something baked into the
/// file. So anything that reads those files and shows them on a Mac has to
/// apply the mask itself, or it shows square tiles.
///
/// The corner is a *continuous* curve rather than a circular arc, which is what
/// `CALayerCornerCurve.continuous` draws. That distinction is the reason this
/// goes through a layer at all instead of `NSBezierPath(roundedRect:…)`, which
/// can only do arcs — and it was measured rather than assumed: rendering the
/// same layer both ways differs on 300 of a 120×120 icon's pixels, so the
/// setting is honoured by `render(in:)` and not quietly ignored.
public enum ApplicationIconMask {
    /// The masked icon, or the image unchanged when there is nothing sensible
    /// to mask.
    ///
    /// Returns the original rather than failing for an image that is not
    /// square: an application icon is square, so a non-square one is some other
    /// kind of image, and cutting superellipse corners into it would be a
    /// guess. Showing it as it is, is not.
    public static func applied(to image: NSImage) -> NSImage {
        guard let squareImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              squareImage.width == squareImage.height,
              squareImage.width > 0,
              let maskedImage = mask(squareImage)
        else { return image }

        // Carries the original's point size over, so the mask changes the
        // shape and nothing about how the image scales where it is drawn.
        return NSImage(cgImage: maskedImage, size: image.size)
    }

    private static func mask(_ squareImage: CGImage) -> CGImage? {
        let side = squareImage.width
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return nil }

        // Masked at the file's own pixel size rather than at the size it will
        // be drawn. The icon column is 22 points and the file is 120 or 180
        // pixels, so the curve is computed with detail to spare and the
        // downscale that follows does the antialiasing.
        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        layer.contents = squareImage
        layer.contentsGravity = .resize
        layer.cornerRadius = CGFloat(side) * cornerRadiusRatio
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.render(in: context)

        return context.makeImage()
    }

    /// The corner radius as a fraction of the icon's side.
    ///
    /// The ratio iOS has used for its application icon mask. Kept as a named
    /// constant because it is a matter of appearance rather than of
    /// correctness: it was settled by rendering this project's own icon at the
    /// size the picker draws it and looking at the result, and retuning it is
    /// one edit.
    private static let cornerRadiusRatio: CGFloat = 0.2237
}

#endif
