import Foundation
import RuntimeViewerAppCore
#if os(macOS)
import AppKit
import AppKitPlus
#else
import UIKit
import UIKitPlus
#endif

/// Draws an object's icon as Xcode draws a code symbol's — the glyph's letters on a squircle of one of
/// Xcode's icon colours — with AppKitPlus's `NSIcon`, UIKitPlus's on iOS and visionOS (the same type
/// there; only the module differs). Keeps each image it drew: the same glyph always gives back the same
/// image.
///
/// The squircle fills a frame of Xcode's icon sizes, `largestFilledFrameSize` and smaller: those are the
/// places RuntimeViewer takes Xcode's metrics — the Find navigator, the jump bar, the history menu, the
/// Inspector's References tab. A larger frame is RuntimeViewer's own — the sidebar's and the
/// specialization picker's 18 points, the Inspector's 20, the start page's and the iOS lists' 24 — and
/// keeps `margin` of room on each side of the icon. The icon is then a point smaller than its frame, which
/// gives it the letters the icons have always had there: NSIcon takes the letters' size from the icon's,
/// and draws 12-point letters on a 17-point icon, 11-point ones on a 16-point icon.
///
/// `NSIcon` caches its images only while they are in use, so the identity a view compares images by is
/// `RuntimeObjectIconImageCache`'s.
final class NSIconRuntimeObjectIconRenderer: RuntimeObjectIconRendering {
    /// The largest frame an icon fills: Xcode's code symbol icons are this size and smaller.
    static let largestFilledFrameSize: CGFloat = 16

    /// The room a larger frame keeps on each side of its icon, before the icon is put on whole pixels.
    static let margin: CGFloat = 0.5

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
            let isHighlighted = glyph.style == .simpleHighlighted
            let frameSize = CGSize(width: glyph.size, height: glyph.size)
            guard glyph.size > Self.largestFilledFrameSize else {
                return Self.image(of: icon, size: frameSize, isHighlighted: isHighlighted)
            }
            let iconSize = CGSize(width: glyph.size - 2 * Self.margin, height: glyph.size - 2 * Self.margin)
            return Self.image(of: icon, size: iconSize, isHighlighted: isHighlighted, centeredInFrameOf: frameSize)
        }
    }

    private static func image(of icon: NSIcon, size: CGSize, isHighlighted: Bool) -> NSUIImage {
        isHighlighted ? icon.highlightedImage(of: size) : icon.image(of: size)
    }

    /// Where an icon of `iconSize` goes in a frame of `frameSize` drawn at `pixelsPerPoint`: in the middle,
    /// moved onto whole pixels. NSIcon lines its plate and letters up with the pixel grid from its own
    /// origin, so an icon put half a pixel off — half a point is that at 1x, and at 3x — would draw them
    /// across pixels, blurred.
    private static func origin(ofIconOf iconSize: CGSize, centeredInFrameOf frameSize: CGSize, pixelsPerPoint: CGFloat) -> CGPoint {
        func onWholePixels(_ length: CGFloat) -> CGFloat {
            (length * pixelsPerPoint).rounded() / pixelsPerPoint
        }
        return CGPoint(
            x: onWholePixels((frameSize.width - iconSize.width) / 2),
            y: onWholePixels((frameSize.height - iconSize.height) / 2)
        )
    }

    #if os(macOS)
    /// Draws `NSIcon`'s image each time it is drawn itself, so the icon takes the appearance it is drawn
    /// in, as `NSIcon`'s own image does, and lands on the pixels of what it is drawn into.
    private static func image(of icon: NSIcon, size iconSize: CGSize, isHighlighted: Bool, centeredInFrameOf frameSize: CGSize) -> NSImage {
        let iconImage = image(of: icon, size: iconSize, isHighlighted: isHighlighted)
        return NSImage(size: frameSize, flipped: false) { frame in
            let deviceScale = NSGraphicsContext.current.map { abs($0.cgContext.userSpaceToDeviceSpaceTransform.a) } ?? 0
            let iconOrigin = Self.origin(ofIconOf: iconSize, centeredInFrameOf: frame.size, pixelsPerPoint: deviceScale > 0 ? deviceScale : 2)
            iconImage.draw(in: CGRect(x: frame.minX + iconOrigin.x, y: frame.minY + iconOrigin.y, width: iconSize.width, height: iconSize.height))
            return true
        }
    }
    #else
    /// One image for each appearance `NSIcon` draws an icon for — light and dark, each at normal and high
    /// contrast — gathered in an image asset as `NSIcon`'s own image is, so the icon follows the traits of
    /// the view it is in.
    private static func image(of icon: NSIcon, size iconSize: CGSize, isHighlighted: Bool, centeredInFrameOf frameSize: CGSize) -> UIImage {
        let currentTraitCollection = UITraitCollection.current
        // What NSIcon draws at when the trait collection has no scale.
        let displayScale = currentTraitCollection.displayScale > 0 ? currentTraitCollection.displayScale : 2
        let iconFrame = CGRect(
            origin: origin(ofIconOf: iconSize, centeredInFrameOf: frameSize, pixelsPerPoint: displayScale),
            size: iconSize
        )
        let imageAsset = UIImageAsset()
        for userInterfaceStyle in [UIUserInterfaceStyle.light, .dark] {
            for accessibilityContrast in [UIAccessibilityContrast.normal, .high] {
                let variantTraitCollection = UITraitCollection { mutableTraits in
                    mutableTraits.userInterfaceStyle = userInterfaceStyle
                    mutableTraits.accessibilityContrast = accessibilityContrast
                    mutableTraits.displayScale = displayScale
                }
                let iconImage = isHighlighted
                    ? icon.highlightedImage(of: iconSize, compatibleWith: variantTraitCollection)
                    : icon.image(of: iconSize, compatibleWith: variantTraitCollection)
                let renderer = UIGraphicsImageRenderer(size: frameSize, format: UIGraphicsImageRendererFormat(for: variantTraitCollection))
                let variantImage = renderer.image { _ in
                    iconImage.draw(in: iconFrame)
                }
                imageAsset.register(variantImage, with: variantTraitCollection)
            }
        }
        return imageAsset.image(with: currentTraitCollection.modifyingTraits { mutableTraits in
            mutableTraits.displayScale = displayScale
        })
    }
    #endif
}

extension NSIconColor {
    /// The icon colour of the same name: a glyph colour is one of `NSIconColor`'s cases, spelt again in
    /// RuntimeViewerAppCore, which links no UI library.
    init(_ color: RuntimeObjectIcon.Glyph.Color) {
        switch color {
        case .background: self = .background
        case .black: self = .black
        case .base: self = .base
        case .blue: self = .blue
        case .brown: self = .brown
        case .bugger: self = .bugger
        case .coreML: self = .coreML
        case .darkBlue: self = .darkBlue
        case .darkPurple: self = .darkPurple
        case .golden: self = .golden
        case .gray: self = .gray
        case .green: self = .green
        case .lightBlue: self = .lightBlue
        case .ocean: self = .ocean
        case .orange: self = .orange
        case .pink: self = .pink
        case .pinkishPurple: self = .pinkishPurple
        case .purple: self = .purple
        case .red: self = .red
        case .steel: self = .steel
        case .swift: self = .swift
        case .teal: self = .teal
        case .text: self = .text
        case .yellow: self = .yellow
        case .clear: self = .clear
        case .white: self = .white
        case .lightPurple: self = .lightPurple
        case .lightGreen: self = .lightGreen
        }
    }
}
