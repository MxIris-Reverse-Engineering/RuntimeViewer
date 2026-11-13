#if os(macOS)

import Testing
import AppKit
@testable import RuntimeViewerUI

/// The mask that makes a device's application icons look like application
/// icons.
///
/// Worth pinning because the input is the thing that is surprising: the icon
/// files inside an iOS bundle are square and **fully opaque**, so every one of
/// these assertions fails open — a mask that quietly did nothing would leave
/// the image exactly as valid as it was, and only look wrong.
@Suite("Application icon mask")
struct ApplicationIconMaskTests {
    @Test("A square icon comes back with its corners cut and its middle intact")
    func cutsTheCornersAndKeepsTheMiddle() throws {
        let masked = ApplicationIconMask.applied(to: opaqueImage(width: 120, height: 120))
        let alpha = try alphaChannel(of: masked)

        // The corner pixel is the whole point.
        #expect(alpha.value(x: 0, y: 0) == 0)
        #expect(alpha.value(x: alpha.width - 1, y: 0) == 0)
        #expect(alpha.value(x: 0, y: alpha.height - 1) == 0)
        #expect(alpha.value(x: alpha.width - 1, y: alpha.height - 1) == 0)

        // And the middle must survive it.
        #expect(alpha.value(x: alpha.width / 2, y: alpha.height / 2) == 255)
        // As must the middle of every edge: the curve is at the corners only,
        // and a mask that had become a circle would fail here while passing
        // every assertion above.
        #expect(alpha.value(x: alpha.width / 2, y: 0) == 255)
        #expect(alpha.value(x: 0, y: alpha.height / 2) == 255)
    }

    /// The guard against the failure with no symptom: `applied(to:)` returns
    /// the image unchanged on every path it cannot handle, so "did it do
    /// anything at all" has to be asserted rather than inferred from the result
    /// being a valid image.
    @Test("The mask removes a meaningful amount, rather than silently doing nothing")
    func removesAMeaningfulAmount() throws {
        let alpha = try alphaChannel(of: ApplicationIconMask.applied(to: opaqueImage(width: 120, height: 120)))
        let transparent = alpha.values.count { $0 == 0 }
        let opaque = alpha.values.count { $0 == 255 }

        #expect(transparent > 0)
        // Four corners off a 120-square is a few percent. The bounds are wide
        // on purpose — this is not pinning the exact curve, it is ruling out
        // "did nothing" on one side and "ate the icon" on the other.
        #expect(Double(transparent) / Double(alpha.values.count) > 0.01)
        #expect(Double(opaque) / Double(alpha.values.count) > 0.85)
    }

    /// An application icon is square, so a non-square image is some other kind
    /// of image and cutting superellipse corners into it would be a guess.
    @Test("A non-square image is returned untouched")
    func nonSquareImageIsUntouched() throws {
        let original = opaqueImage(width: 120, height: 60)
        let result = ApplicationIconMask.applied(to: original)
        let alpha = try alphaChannel(of: result)
        #expect(alpha.values.allSatisfy { $0 == 255 })
    }

    /// The point size is what decides how the image draws where it is placed,
    /// so the mask must change the shape and nothing else. A result that came
    /// back sized in pixels would render at five times the intended size in the
    /// picker's icon column.
    @Test("The point size survives the mask")
    func pointSizeIsPreserved() {
        let original = opaqueImage(width: 120, height: 120)
        original.size = NSSize(width: 60, height: 60)
        let masked = ApplicationIconMask.applied(to: original)
        #expect(masked.size == NSSize(width: 60, height: 60))
    }
}

// MARK: - Fixtures

/// A fully opaque image, which is what an iOS bundle's icon file actually is.
private func opaqueImage(width: Int, height: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.red.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
    image.unlockFocus()
    return image
}

private struct AlphaChannel {
    let width: Int
    let height: Int
    let values: [UInt8]

    func value(x: Int, y: Int) -> UInt8 {
        values[y * width + x]
    }
}

private func alphaChannel(of image: NSImage) throws -> AlphaChannel {
    let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let width = cgImage.width
    let height = cgImage.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(
        CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        )
    )
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return AlphaChannel(
        width: width,
        height: height,
        values: stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] },
    )
}

#endif
