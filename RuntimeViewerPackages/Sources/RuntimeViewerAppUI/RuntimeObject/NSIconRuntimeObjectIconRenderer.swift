import Foundation
import RuntimeViewerAppCore
#if os(macOS)
import AppKitPlus
#else
import UIKitPlus
#endif

/// Draws an object's icon as Xcode draws a code symbol's — the glyph's letters on a squircle of one of
/// Xcode's icon colours, filling the whole image — with AppKitPlus's `NSIcon`, UIKitPlus's on iOS and
/// visionOS (the same type there; only the module differs). Keeps each image it drew: the same glyph
/// always gives back the same image.
///
/// `NSIcon` caches its images only while they are in use, so the identity a view compares images by is
/// `RuntimeObjectIconImageCache`'s.
final class NSIconRuntimeObjectIconRenderer: RuntimeObjectIconRendering {
    private let imageCache = RuntimeObjectIconImageCache()

    func image(for glyph: RuntimeObjectIcon.Glyph) -> NSUIImage {
        imageCache.image(for: glyph) { glyph in
            let specification = NSGeneratedIconSpecification(
                letters: glyph.text,
                shape: .squircle,
                backgroundColor: NSIconColor(glyph.color).color,
                glyphColor: nil
            )
            let icon = NSIcon(generatedIconSpecification: specification)
            let imageSize = CGSize(width: glyph.size, height: glyph.size)
            switch glyph.style {
            case .simple:
                return icon.image(of: imageSize)
            case .simpleHighlighted:
                return icon.highlightedImage(of: imageSize)
            }
        }
    }
}

extension NSIconColor {
    /// The icon colour a glyph colour is drawn on: the system colour of the same name, which the glyph
    /// colours have always been. Xcode names four of them otherwise.
    init(_ color: RuntimeObjectIcon.Glyph.Color) {
        switch color {
        case .blue: self = .blue
        case .brown: self = .brown
        case .gray: self = .gray
        case .green: self = .green
        case .orange: self = .orange
        case .pink: self = .pink
        // systemPurple
        case .purple: self = .pinkishPurple
        case .red: self = .red
        case .teal: self = .teal
        case .yellow: self = .yellow
        // systemIndigo
        case .indigo: self = .purple
        // systemMint
        case .mint: self = .ocean
        // systemCyan
        case .cyan: self = .coreML
        }
    }
}
