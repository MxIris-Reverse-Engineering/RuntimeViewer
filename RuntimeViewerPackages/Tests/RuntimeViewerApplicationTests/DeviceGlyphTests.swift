#if os(macOS)

import Testing
import AppKit
@testable import RuntimeViewerUI

/// The glyph the engine list shows for a machine.
///
/// Every assertion here is about a *silent* wrong answer: each of the images
/// involved is a perfectly valid one, so none of these failures would announce
/// itself — a Cinema Display stood in for an iPhone for as long as the feature
/// existed, and nothing logged a thing.
@Suite("Device glyph")
struct DeviceGlyphTests {
    /// The engine menu pins every item's image to 20×20. A symbol image is not
    /// square — `iphone.gen3` is 14×16, `macstudio` is 19×11 — so one handed
    /// over unsquared is *stretched* into that box, which turns a Mac Studio
    /// into a cube.
    @Test("The glyph is square, whatever the device's proportions")
    func glyphIsSquare() throws {
        for modelIdentifier in ["iPhone16,2", "iPad13,1", "Mac14,14"] {
            let glyph = try #require(image(forModelIdentifier: modelIdentifier))
            #expect(glyph.size.width == glyph.size.height, "\(modelIdentifier) came back \(glyph.size)")
        }
    }

    /// The model code names the exact device and the platform only names its
    /// family, so the order matters: a Mac that reported `iOS` — nonsense, but
    /// the sort of nonsense a peer can send — must still be drawn as the Mac it
    /// says it is.
    @Test("A model macOS recognises wins over the platform")
    func declaredModelWinsOverPlatform() throws {
        let macStudio = try #require(image(forModelIdentifier: "Mac14,14", operatingSystemVersion: "iOS 26.5.0"))
        let iPhone = try #require(image(forModelIdentifier: unknownIOSModelIdentifier))
        #expect(pixels(of: macStudio) != pixels(of: iPhone))
        // A Mac Studio has no screen to light up, so the second palette colour
        // has nothing to land on — which is the behaviour, not a bug.
        #expect(!hasLitScreen(macStudio))
    }

    /// Why the platform is only a fallback: real hardware reports a *board*
    /// identifier rather than a marketing model identifier — an iPhone's
    /// `hw.model` is `D74AP`, not `iPhone15,3` — and CoreTypes declares both, so
    /// a physical device never needs the fallback at all.
    @Test("A real iPhone's board identifier resolves on its own")
    func boardIdentifierResolvesWithoutThePlatform() {
        #expect(image(forModelIdentifier: "D74AP", operatingSystemVersion: "") != nil)
    }

    /// The case that prompted all of this: a VM's model code is undeclared, and
    /// the icon it used to get was a generic display.
    @Test("An unrecognised model on iOS falls back to an iPhone")
    func unrecognisedIOSModelFallsBackToAnIPhone() throws {
        let fallback = try #require(image(forModelIdentifier: unknownIOSModelIdentifier))
        let realIPhone = try #require(image(forModelIdentifier: "iPhone16,2"))
        #expect(pixels(of: fallback) == pixels(of: realIPhone))
    }

    /// A Mac VM's model code is undeclared too, and a Mac is exactly what the
    /// caller's generic fallback suits. Reporting the miss is what keeps that
    /// behaviour unchanged instead of drawing a phone.
    @Test("An unrecognised model on macOS reports the miss")
    func unrecognisedMacModelReportsTheMiss() {
        #expect(image(forModelIdentifier: "VirtualMac2,1", operatingSystemVersion: "macOS 27.0.0") == nil)
    }

    /// A platform with no mapping must not borrow the iPhone's.
    @Test("An unrecognised model on an unmapped platform reports the miss")
    func unrecognisedModelOnUnmappedPlatformReportsTheMiss() {
        #expect(image(forModelIdentifier: "Unknown", operatingSystemVersion: "Unknown 1.0.0") == nil)
        #expect(image(forModelIdentifier: "Unknown", operatingSystemVersion: "") == nil)
    }

    /// The lit screen is the whole two-tone treatment, and it is also what tells
    /// a simulator from hardware now that both are drawn as symbols.
    @Test("Hardware gets a lit screen and a simulator does not")
    func simulatorIsDrawnInOneColour() throws {
        let hardware = try #require(image(forModelIdentifier: "iPhone16,2"))
        let simulator = try #require(image(forModelIdentifier: "iPhone16,2", isSimulator: true))
        #expect(hasLitScreen(hardware))
        #expect(!hasLitScreen(simulator))
    }

    /// The body is the label colour — measured `#E0E0E1` against a screenshot of
    /// Xcode's own row — so a neutral layer has to be there at all. On its own
    /// this says nothing about *which* layer; it is the pair with the lit-screen
    /// test above that pins the order, and reordering the palette fails that one.
    @Test("The body is drawn in a neutral colour, not a tint")
    func bodyIsNeutral() throws {
        let glyph = try #require(image(forModelIdentifier: "iPhone16,2"))
        #expect(hasNeutralBody(glyph), "every opaque pixel is tinted, so the first palette colour is a blue")
    }

    /// The screen runs lighter at the top, which a flat fill does not do and
    /// which is visibly not the same picture. `colorRenderingMode` is a request
    /// that can be ignored — a symbol with no colour layers would come back
    /// unshaded and perfectly valid-looking — so it is asked of the pixels.
    @Test("The screen is shaded rather than filled flat")
    func screenIsShaded() throws {
        // The switch arrived in macOS 26; before it the implementation keeps the
        // flat fill on purpose, so there is nothing to assert.
        guard #available(macOS 26.0, *) else { return }
        let glyph = try #require(image(forModelIdentifier: "iPhone16,2"))
        let upper = try #require(screenSample(of: glyph, atFractionDown: 0.32))
        let lower = try #require(screenSample(of: glyph, atFractionDown: 0.70))
        #expect(upper != lower, "the screen is one flat colour: \(upper)")
    }
}

// MARK: - Fixtures

/// Shaped like a model identifier and declared by nothing — the stand-in for
/// whatever a virtual device reports.
private let unknownIOSModelIdentifier = "VirtualiPhone1,1"

private func image(
    forModelIdentifier modelIdentifier: String,
    operatingSystemVersion: String = "iOS 26.5.0",
    isSimulator: Bool = false,
) -> NSImage? {
    DeviceGlyph.image(
        forModelIdentifier: modelIdentifier,
        operatingSystemVersion: operatingSystemVersion,
        isSimulator: isSimulator,
    )
}

/// Whether the glyph has a lit screen anywhere. Asked of the pixels rather than
/// of the configuration, because a palette colour that silently fails to apply
/// is exactly the failure worth catching.
private func hasLitScreen(_ image: NSImage) -> Bool {
    let samples = pixels(of: image, side: 48)
    return stride(from: 0, to: samples.count, by: 4).contains { offset in
        isLitScreen(samples[offset ..< offset + 4])
    }
}

/// The colour of the screen down the glyph's midline, `fractionDown` of the way
/// from its top, or `nil` where that point is not screen.
///
/// Row 0 of a bitmap context's buffer is the image's top row, so the fraction
/// reads the way it is written.
private func screenSample(of image: NSImage, atFractionDown fractionDown: Double, side: Int = 64) -> [UInt8]? {
    let samples = pixels(of: image, side: side)
    let offset = (Int(Double(side) * fractionDown) * side + side / 2) * 4
    let pixel = Array(samples[offset ..< offset + 4])
    return isLitScreen(pixel) ? pixel : nil
}

/// Whether the glyph has a bright *neutral* region — its body, drawn in the
/// label colour.
///
/// Antialiasing fades a premultiplied pixel toward transparency rather than
/// toward grey, so it preserves hue: a neutral opaque pixel means a neutral
/// layer, not a soft edge of a blue one.
private func hasNeutralBody(_ image: NSImage, side: Int = 64) -> Bool {
    let samples = pixels(of: image, side: side)
    return stride(from: 0, to: samples.count, by: 4).contains { offset in
        let red = Int(samples[offset]), green = Int(samples[offset + 1])
        let blue = Int(samples[offset + 2]), alpha = Int(samples[offset + 3])
        return alpha > 200 && red > 150 && abs(red - green) <= 8 && abs(green - blue) <= 8
    }
}

/// Whether a pixel is distinctly blue — the screen the palette's blues light up.
private func isLitScreen(_ pixel: some Collection<UInt8>) -> Bool {
    let channels = Array(pixel)
    let red = Int(channels[0]), green = Int(channels[1])
    let blue = Int(channels[2]), alpha = Int(channels[3])
    return alpha > 200 && blue > 150 && blue > red + 60 && blue > green + 40
}

private func pixels(of image: NSImage, side: Int = 48) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: side * side * 4)
    guard let context = CGContext(
        data: &buffer,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ) else { return buffer }
    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return buffer
}

#endif
