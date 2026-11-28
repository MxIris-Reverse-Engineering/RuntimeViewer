import AppKit
import AppKitPlus
import Testing
import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI

/// RuntimeViewerAppUI draws the glyphs RuntimeViewerAppCore picks as Xcode draws a code symbol's icon,
/// with AppKitPlus's `NSIcon` (proposal `nsicon-object-icons`): the glyph's letters on a squircle, in the
/// system colour the glyph's colour is named after. The squircle fills a frame of Xcode's icon sizes, 16
/// points and smaller, and keeps half a point of room on each side of a larger one, on whole pixels. The
/// glyphs themselves are RuntimeViewerAppCore's, tested in `RuntimeObjectIconGlyphTests`.
///
/// On the main actor because the images are drawn with AppKit, as the cell views draw them.
@Suite("NSIcon object icon renderer")
@MainActor
struct NSIconRuntimeObjectIconRendererTests {
    @Test("Each glyph colour is drawn on the system colour of the same name, in light and dark appearances", arguments: [
        (color: RuntimeObjectIcon.Glyph.Color.blue, systemColor: NSColor.systemBlue),
        (color: .brown, systemColor: .systemBrown),
        (color: .gray, systemColor: .systemGray),
        (color: .green, systemColor: .systemGreen),
        (color: .orange, systemColor: .systemOrange),
        (color: .pink, systemColor: .systemPink),
        (color: .purple, systemColor: .systemPurple),
        (color: .red, systemColor: .systemRed),
        (color: .teal, systemColor: .systemTeal),
        (color: .yellow, systemColor: .systemYellow),
        (color: .indigo, systemColor: .systemIndigo),
        (color: .mint, systemColor: .systemMint),
        (color: .cyan, systemColor: .systemCyan),
    ])
    func glyphColourIsTheSystemColourOfTheSameName(color: RuntimeObjectIcon.Glyph.Color, systemColor: NSColor) {
        let iconColor = NSIconColor(color).color

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(
                Self.sRGBComponents(of: iconColor, in: appearanceName) == Self.sRGBComponents(of: systemColor, in: appearanceName),
                "\(color) in \(appearanceName.rawValue)"
            )
        }
    }

    @Test("A glyph is drawn as NSIcon draws its letters on a squircle of its colour")
    func simpleGlyphMatchesNSIcon() {
        let glyph = RuntimeObjectIcon.Glyph(text: "Pr", color: .purple, style: .simple, size: 16)

        let drawnIcon = NSIconRuntimeObjectIconRenderer().image(for: glyph)

        let expectedIcon = Self.icon(letters: "Pr", color: .pinkishPurple).image(of: NSSize(width: 16, height: 16))
        #expect(drawnIcon.tiffRepresentation == expectedIcon.tiffRepresentation)
    }

    @Test("A highlighted glyph is NSIcon's highlighted image: a white plate with the letters cut out")
    func highlightedGlyphMatchesNSIconsHighlightedImage() {
        let glyph = RuntimeObjectIcon.Glyph(text: "C", color: .orange, style: .simpleHighlighted, size: 16)

        let drawnIcon = NSIconRuntimeObjectIconRenderer().image(for: glyph)

        let expectedIcon = Self.icon(letters: "C", color: .orange).highlightedImage(of: NSSize(width: 16, height: 16))
        #expect(drawnIcon.tiffRepresentation == expectedIcon.tiffRepresentation)
    }

    @Test("In a frame of Xcode's icon sizes the image is the glyph's size and its plate reaches every edge of it", arguments: [14.0, 16.0] as [CGFloat])
    func plateFillsAFrameOfXcodesIconSizes(size: CGFloat) {
        let glyph = RuntimeObjectIcon.Glyph(text: "C", color: .blue, style: .simple, size: size)

        let drawnIcon = NSIconRuntimeObjectIconRenderer().image(for: glyph)

        #expect(drawnIcon.size == NSSize(width: size, height: size))
        let bitmap = Self.bitmap(of: drawnIcon, scale: 2)
        let middle = bitmap.pixelsWide / 2
        let last = bitmap.pixelsWide - 1
        for (pixelColumn, pixelRow) in [(0, middle), (last, middle), (middle, 0), (middle, last)] {
            #expect(
                (bitmap.colorAt(x: pixelColumn, y: pixelRow)?.alphaComponent ?? 0) > 0.9,
                "pixel (\(pixelColumn), \(pixelRow)) of a \(size)-point icon"
            )
        }
    }

    @Test("In a larger frame the image is the glyph's size and its plate keeps half a point of room on every side", arguments: [18.0, 20.0, 24.0] as [CGFloat])
    func largerFrameKeepsHalfAPointOfRoomAroundThePlate(size: CGFloat) {
        let glyph = RuntimeObjectIcon.Glyph(text: "C", color: .blue, style: .simple, size: size)

        let drawnIcon = NSIconRuntimeObjectIconRenderer().image(for: glyph)

        #expect(drawnIcon.size == NSSize(width: size, height: size))
        let bitmap = Self.bitmap(of: drawnIcon, scale: 2)
        let middle = bitmap.pixelsWide / 2
        let last = bitmap.pixelsWide - 1
        // At 2x the half point of room is a pixel, and the plate starts on the second.
        let roomPixels = [(0, middle), (last, middle), (middle, 0), (middle, last)]
        for (pixelColumn, pixelRow) in roomPixels {
            #expect(
                (bitmap.colorAt(x: pixelColumn, y: pixelRow)?.alphaComponent ?? 1) < 0.05,
                "pixel (\(pixelColumn), \(pixelRow)) of a \(size)-point icon"
            )
        }
        for (pixelColumn, pixelRow) in [(1, middle), (last - 1, middle), (middle, 1), (middle, last - 1)] {
            #expect(
                (bitmap.colorAt(x: pixelColumn, y: pixelRow)?.alphaComponent ?? 0) > 0.9,
                "pixel (\(pixelColumn), \(pixelRow)) of a \(size)-point icon"
            )
        }
    }

    @Test("A larger frame holds, in its middle, the icon NSIcon draws a point smaller", arguments: [RuntimeObjectIcon.Glyph.Style.simple, .simpleHighlighted])
    func largerFrameHoldsTheIconAPointSmaller(style: RuntimeObjectIcon.Glyph.Style) {
        let glyph = RuntimeObjectIcon.Glyph(text: "Pr", color: .purple, style: style, size: 18)

        let drawnIcon = NSIconRuntimeObjectIconRenderer().image(for: glyph)

        let icon = Self.icon(letters: "Pr", color: .pinkishPurple)
        let iconSize = NSSize(width: 17, height: 17)
        let expectedIcon = style == .simple ? icon.image(of: iconSize) : icon.highlightedImage(of: iconSize)
        let mismatchedPixelCount = Self.mismatchedPixelCount(
            in: Self.bitmap(of: drawnIcon, scale: 2),
            offsetBy: (column: 1, row: 1),
            comparedWith: Self.bitmap(of: expectedIcon, scale: 2)
        )
        #expect(mismatchedPixelCount == 0)
    }

    // Half a point is half a pixel at 1x: an icon put there would draw its plate and letters across pixels,
    // blurred. On whole pixels it sits one pixel from the left and bottom edges and none from the others.
    @Test("A larger frame puts its icon on whole pixels, where it is drawn as sharply as NSIcon draws it")
    func largerFramePutsTheIconOnWholePixels() {
        let glyph = RuntimeObjectIcon.Glyph(text: "C", color: .orange, style: .simple, size: 18)

        let drawnIcon = NSIconRuntimeObjectIconRenderer().image(for: glyph)

        let expectedIcon = Self.icon(letters: "C", color: .orange).image(of: NSSize(width: 17, height: 17))
        let mismatchedPixelCount = Self.mismatchedPixelCount(
            in: Self.bitmap(of: drawnIcon, scale: 1),
            offsetBy: (column: 1, row: 0),
            comparedWith: Self.bitmap(of: expectedIcon, scale: 1)
        )
        #expect(mismatchedPixelCount == 0)
    }

    @Test("A larger frame draws its icon in the appearance it is drawn in, as NSIcon's own image does")
    func largerFrameFollowsTheAppearance() {
        let glyph = RuntimeObjectIcon.Glyph(text: "C", color: .blue, style: .simple, size: 18)

        let drawnIcon = NSIconRuntimeObjectIconRenderer().image(for: glyph)

        let expectedIcon = Self.icon(letters: "C", color: .blue).image(of: NSSize(width: 17, height: 17))
        let lightIcon = Self.bitmap(of: expectedIcon, scale: 2, in: .aqua)
        let darkIcon = Self.bitmap(of: expectedIcon, scale: 2, in: .darkAqua)
        // Otherwise the two appearances could not tell a drawing that follows them from one that does not.
        #expect(Self.mismatchedPixelCount(in: lightIcon, offsetBy: (column: 0, row: 0), comparedWith: darkIcon) > 0)
        for (appearanceName, expectedPixels) in [(NSAppearance.Name.aqua, lightIcon), (.darkAqua, darkIcon)] {
            let mismatchedPixelCount = Self.mismatchedPixelCount(
                in: Self.bitmap(of: drawnIcon, scale: 2, in: appearanceName),
                offsetBy: (column: 1, row: 1),
                comparedWith: expectedPixels
            )
            #expect(mismatchedPixelCount == 0, "\(appearanceName.rawValue)")
        }
    }

    @Test("The live renderer is the NSIcon one")
    func liveRendererIsTheNSIconOne() {
        #expect(RuntimeObjectIconRenderingKey.liveValue is NSIconRuntimeObjectIconRenderer)
    }

    private static func icon(letters: String, color: NSIconColor) -> NSIcon {
        NSIcon(generatedIconSpecification: NSGeneratedIconSpecification(letters: letters, shape: .squircle, backgroundColor: color.color, glyphColor: nil))
    }

    private static func sRGBComponents(of color: NSColor, in appearanceName: NSAppearance.Name) -> [CGFloat] {
        var components: [CGFloat] = []
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            guard let resolvedColor = color.usingColorSpace(.sRGB) else { return }
            components = [resolvedColor.redComponent, resolvedColor.greenComponent, resolvedColor.blueComponent, resolvedColor.alphaComponent]
        }
        return components
    }

    /// `image` drawn into a bitmap of `scale` pixels a point, in the appearance named `appearanceName` when
    /// there is one.
    private static func bitmap(of image: NSImage, scale: Int, in appearanceName: NSAppearance.Name? = nil) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width) * scale,
            pixelsHigh: Int(image.size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        bitmap.size = image.size
        let draw = {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
        }
        if let appearanceName, let appearance = NSAppearance(named: appearanceName) {
            appearance.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        return bitmap
    }

    /// How many pixels of `expectedBitmap` differ, by more than two levels in a channel, from the pixels of
    /// `bitmap` `pixelOffset.column` pixels in from its left edge and `pixelOffset.row` from its top.
    private static func mismatchedPixelCount(in bitmap: NSBitmapImageRep, offsetBy pixelOffset: (column: Int, row: Int), comparedWith expectedBitmap: NSBitmapImageRep) -> Int {
        var mismatchedPixelCount = 0
        var samples = [Int](repeating: 0, count: 4)
        var expectedSamples = [Int](repeating: 0, count: 4)
        for pixelRow in 0 ..< expectedBitmap.pixelsHigh {
            for pixelColumn in 0 ..< expectedBitmap.pixelsWide {
                bitmap.getPixel(&samples, atX: pixelColumn + pixelOffset.column, y: pixelRow + pixelOffset.row)
                expectedBitmap.getPixel(&expectedSamples, atX: pixelColumn, y: pixelRow)
                if zip(samples, expectedSamples).contains(where: { abs($0 - $1) > 2 }) {
                    mismatchedPixelCount += 1
                }
            }
        }
        return mismatchedPixelCount
    }
}
