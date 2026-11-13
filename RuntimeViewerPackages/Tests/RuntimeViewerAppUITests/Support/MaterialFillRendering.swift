import AppKit
import SwiftUI
import Testing

/// What SwiftUI draws for `.fill.secondary` with a background material in the environment, which is
/// the track of Xcode 27's activity ring: `IDEActivityWindowTitleView.documentIconProgressIndicator`
/// strokes it as `Circle().strokeBorder(.fill.secondary)` under
/// `.environment(\.backgroundMaterial, .regular)` (IDEKit 27.2 27B52, 0xA526A0 and 0xA59074).
///
/// The ring is rendered offscreen over a flat grey of `backdropWhite` (0 to 255) and sampled on its
/// stroke; the result is the sRGB red, green and blue there, 0 to 255. Over a material SwiftUI blends
/// the fill with what is behind it instead of laying it on top, so this is how the track looks in
/// Xcode's window title — checked against a screenshot of Xcode 27.2, whose track over the toolbar's
/// #202027 measured #34343A. `opacity` is the `.opacity` Xcode gives the slot of a window that is not
/// key (0.5), which SwiftUI applies to the track itself, so the track still blends.
@MainActor
func secondaryFillOverMaterial(isDark: Bool, backdropWhite: Int, opacity: Double = 1, sourceLocation: SourceLocation = #_sourceLocation) throws -> [Double] {
    _ = NSApplication.shared
    let backdropComponent = Double(backdropWhite) / 255
    let ringSide = 40
    let lineWidth: CGFloat = 8
    let content = ZStack {
        Color(.sRGB, red: backdropComponent, green: backdropComponent, blue: backdropComponent, opacity: 1)
        Circle()
            .strokeBorder(.fill.secondary, lineWidth: lineWidth)
            .opacity(opacity)
            .environment(\.backgroundMaterial, .regular)
    }
    .frame(width: CGFloat(ringSide), height: CGFloat(ringSide))
    .environment(\.colorScheme, isDark ? .dark : .light)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 1
    let image = try #require(renderer.cgImage, sourceLocation: sourceLocation)
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB), sourceLocation: sourceLocation)
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    return try bytes.withUnsafeMutableBytes { buffer in
        let context = try #require(CGContext(
            data: buffer.baseAddress,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), sourceLocation: sourceLocation)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Halfway through the stroke at twelve o'clock.
        let row = Int(lineWidth / 2)
        let offset = (row * image.width + image.width / 2) * 4
        return (0..<3).map { Double(buffer[offset + $0]) }
    }
}
