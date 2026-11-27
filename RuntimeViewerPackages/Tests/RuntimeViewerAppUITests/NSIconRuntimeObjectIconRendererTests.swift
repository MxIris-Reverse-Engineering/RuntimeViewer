import AppKit
import AppKitPlus
import Testing
import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI

/// RuntimeViewerAppUI draws the glyphs RuntimeViewerAppCore picks as Xcode draws a code symbol's icon,
/// with AppKitPlus's `NSIcon` (proposal `nsicon-object-icons`): the glyph's letters on a squircle that
/// fills the whole image, in the system colour the glyph's colour is named after. The glyphs themselves
/// are RuntimeViewerAppCore's, tested in `RuntimeObjectIconGlyphTests`.
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
        let glyph = RuntimeObjectIcon.Glyph(text: "Pr", color: .purple, style: .simple, size: 18)

        let drawnIcon = NSIconRuntimeObjectIconRenderer().image(for: glyph)

        let expectedIcon = Self.icon(letters: "Pr", color: .pinkishPurple).image(of: NSSize(width: 18, height: 18))
        #expect(drawnIcon.tiffRepresentation == expectedIcon.tiffRepresentation)
    }

    @Test("A highlighted glyph is NSIcon's highlighted image: a white plate with the letters cut out")
    func highlightedGlyphMatchesNSIconsHighlightedImage() {
        let glyph = RuntimeObjectIcon.Glyph(text: "C", color: .orange, style: .simpleHighlighted, size: 16)

        let drawnIcon = NSIconRuntimeObjectIconRenderer().image(for: glyph)

        let expectedIcon = Self.icon(letters: "C", color: .orange).highlightedImage(of: NSSize(width: 16, height: 16))
        #expect(drawnIcon.tiffRepresentation == expectedIcon.tiffRepresentation)
    }

    @Test("The image is the glyph's size and its plate reaches every edge of it", arguments: [14.0, 16.0, 18.0, 24.0] as [CGFloat])
    func plateFillsTheGlyphsSize(size: CGFloat) {
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

    private static func bitmap(of image: NSImage, scale: Int) -> NSBitmapImageRep {
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
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}
