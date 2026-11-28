import AppKit
import AppKitPlus
import Testing
import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI

/// RuntimeViewerAppUI draws the glyphs RuntimeViewerAppCore picks as Xcode draws a code symbol's icon,
/// with AppKitPlus's `NSIcon` (proposal `nsicon-object-icons`): the glyph's letters on a squircle, in the
/// system colour the glyph's colour is named after. The squircle fills a frame of Xcode's icon sizes, 16
/// points and smaller, and keeps a point of room on each side of a larger one. The glyphs themselves are
/// RuntimeViewerAppCore's, tested in `RuntimeObjectIconGlyphTests`.
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

    @Test("In a larger frame the image is the glyph's size and its plate keeps a point of room on every side", arguments: [18.0, 20.0, 24.0] as [CGFloat])
    func largerFrameKeepsAPointOfRoomAroundThePlate(size: CGFloat) {
        let glyph = RuntimeObjectIcon.Glyph(text: "C", color: .blue, style: .simple, size: size)

        let drawnIcon = NSIconRuntimeObjectIconRenderer().image(for: glyph)

        #expect(drawnIcon.size == NSSize(width: size, height: size))
        let bitmap = Self.bitmap(of: drawnIcon, scale: 2)
        let middle = bitmap.pixelsWide / 2
        let last = bitmap.pixelsWide - 1
        // At 2x the point of room is two pixels, and the plate starts on the third.
        let roomPixels = [(0, middle), (1, middle), (last, middle), (last - 1, middle), (middle, 0), (middle, 1), (middle, last), (middle, last - 1)]
        for (pixelColumn, pixelRow) in roomPixels {
            #expect(
                (bitmap.colorAt(x: pixelColumn, y: pixelRow)?.alphaComponent ?? 1) < 0.05,
                "pixel (\(pixelColumn), \(pixelRow)) of a \(size)-point icon"
            )
        }
        for (pixelColumn, pixelRow) in [(2, middle), (last - 2, middle), (middle, 2), (middle, last - 2)] {
            #expect(
                (bitmap.colorAt(x: pixelColumn, y: pixelRow)?.alphaComponent ?? 0) > 0.9,
                "pixel (\(pixelColumn), \(pixelRow)) of a \(size)-point icon"
            )
        }
    }

    @Test("A larger frame holds, in its middle, the icon NSIcon draws two points smaller", arguments: [RuntimeObjectIcon.Glyph.Style.simple, .simpleHighlighted])
    func largerFrameHoldsTheIconTwoPointsSmaller(style: RuntimeObjectIcon.Glyph.Style) {
        let glyph = RuntimeObjectIcon.Glyph(text: "Pr", color: .purple, style: style, size: 18)

        let drawnIcon = NSIconRuntimeObjectIconRenderer().image(for: glyph)

        let icon = Self.icon(letters: "Pr", color: .pinkishPurple)
        let iconSize = NSSize(width: 16, height: 16)
        let expectedIcon = style == .simple ? icon.image(of: iconSize) : icon.highlightedImage(of: iconSize)
        let mismatchedPixelCount = Self.mismatchedPixelCount(
            in: Self.bitmap(of: drawnIcon, scale: 2),
            offsetBy: 2,
            comparedWith: Self.bitmap(of: expectedIcon, scale: 2)
        )
        #expect(mismatchedPixelCount == 0)
    }

    @Test("A larger frame draws its icon in the appearance it is drawn in, as NSIcon's own image does")
    func largerFrameFollowsTheAppearance() {
        let glyph = RuntimeObjectIcon.Glyph(text: "C", color: .blue, style: .simple, size: 18)

        let drawnIcon = NSIconRuntimeObjectIconRenderer().image(for: glyph)

        let expectedIcon = Self.icon(letters: "C", color: .blue).image(of: NSSize(width: 16, height: 16))
        let lightIcon = Self.bitmap(of: expectedIcon, scale: 2, in: .aqua)
        let darkIcon = Self.bitmap(of: expectedIcon, scale: 2, in: .darkAqua)
        // Otherwise the two appearances could not tell a drawing that follows them from one that does not.
        #expect(Self.mismatchedPixelCount(in: lightIcon, offsetBy: 0, comparedWith: darkIcon) > 0)
        for (appearanceName, expectedPixels) in [(NSAppearance.Name.aqua, lightIcon), (.darkAqua, darkIcon)] {
            let mismatchedPixelCount = Self.mismatchedPixelCount(
                in: Self.bitmap(of: drawnIcon, scale: 2, in: appearanceName),
                offsetBy: 2,
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
    /// `bitmap` `pixelOffset` pixels in from its top and left edges.
    private static func mismatchedPixelCount(in bitmap: NSBitmapImageRep, offsetBy pixelOffset: Int, comparedWith expectedBitmap: NSBitmapImageRep) -> Int {
        var mismatchedPixelCount = 0
        var samples = [Int](repeating: 0, count: 4)
        var expectedSamples = [Int](repeating: 0, count: 4)
        for pixelRow in 0 ..< expectedBitmap.pixelsHigh {
            for pixelColumn in 0 ..< expectedBitmap.pixelsWide {
                bitmap.getPixel(&samples, atX: pixelColumn + pixelOffset, y: pixelRow + pixelOffset)
                expectedBitmap.getPixel(&expectedSamples, atX: pixelColumn, y: pixelRow)
                if zip(samples, expectedSamples).contains(where: { abs($0 - $1) > 2 }) {
                    mismatchedPixelCount += 1
                }
            }
        }
        return mismatchedPixelCount
    }
}
