import Foundation
import Dependencies
import RuntimeViewerCore
import RuntimeViewerAppCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The images of the glyphs RuntimeViewerAppCore picks (`RuntimeObjectIcon.glyph(for:)` and its
/// siblings), drawn by `runtimeObjectIconRendering`. Each takes the arguments of the glyph it draws.
extension RuntimeObjectIcon {
    public static func icon(text: String, color: Glyph.Color, size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> NSUIImage {
        image(for: glyph(text: text, color: color, size: size, style: style))
    }

    public static func iconForGeneric(size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> NSUIImage {
        image(for: genericGlyph(size: size, style: style))
    }

    public static func iconForSpecialized(size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> NSUIImage {
        image(for: specializedGlyph(size: size, style: style))
    }

    public static func iconForObjCImplementation(size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> NSUIImage {
        image(for: objcImplementationGlyph(size: size, style: style))
    }

    public static func icon(for kind: RuntimeObjectKind, size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> NSUIImage {
        image(for: glyph(for: kind, size: size, style: style))
    }

    public static func secondaryIcon(for object: RuntimeObject, size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> NSUIImage? {
        secondaryGlyph(for: object, size: size, style: style).map(image(for:))
    }

    /// `glyph` as drawn by the current `runtimeObjectIconRendering`.
    public static func image(for glyph: Glyph) -> NSUIImage {
        @Dependency(\.runtimeObjectIconRendering) var runtimeObjectIconRendering
        return runtimeObjectIconRendering.image(for: glyph)
    }
}

// MARK: - Drawing

/// Draws an object's icon. The live value draws it the way Xcode draws a symbol's kind, with
/// UIFoundation's `IDEIcon` (`IDEIconRuntimeObjectIconRenderer`); RuntimeViewerAppCore only picks the
/// glyph.
///
/// A renderer gives back the same image for the same glyph, as the icons always have: a view that
/// compares the images it was given redraws only when they differ.
public protocol RuntimeObjectIconRendering: AnyObject, Sendable {
    func image(for glyph: RuntimeObjectIcon.Glyph) -> NSUIImage
}

/// The live value draws with `IDEIcon`; a test gets blank images of the glyph's size, so that a test
/// that does not care what an icon shows does not draw it.
enum RuntimeObjectIconRenderingKey: DependencyKey {
    static let liveValue: any RuntimeObjectIconRendering = IDEIconRuntimeObjectIconRenderer()
    static let testValue: any RuntimeObjectIconRendering = BlankRuntimeObjectIconRenderer()
}

extension DependencyValues {
    public var runtimeObjectIconRendering: any RuntimeObjectIconRendering {
        get { self[RuntimeObjectIconRenderingKey.self] }
        set { self[RuntimeObjectIconRenderingKey.self] = newValue }
    }
}

/// One image per glyph, drawn the first time it is asked for. The lock guards the dictionary; drawing
/// happens under it, so a glyph is never drawn twice.
package final class RuntimeObjectIconImageCache: @unchecked Sendable {
    private let lock = NSLock()

    private var imagesByGlyph: [RuntimeObjectIcon.Glyph: NSUIImage] = [:]

    package init() {}

    package func image(for glyph: RuntimeObjectIcon.Glyph, drawing draw: (RuntimeObjectIcon.Glyph) -> NSUIImage) -> NSUIImage {
        lock.lock()
        defer { lock.unlock() }
        if let image = imagesByGlyph[glyph] {
            return image
        }
        let image = draw(glyph)
        imagesByGlyph[glyph] = image
        return image
    }
}

/// The icons a test gets: an empty image of the glyph's size, one per glyph. A test that cares what an
/// icon shows compares glyphs (`RuntimeObjectIcon.glyph(for:)`), not pixels.
final class BlankRuntimeObjectIconRenderer: RuntimeObjectIconRendering {
    private let imageCache = RuntimeObjectIconImageCache()

    func image(for glyph: RuntimeObjectIcon.Glyph) -> NSUIImage {
        imageCache.image(for: glyph) { glyph in
            #if os(macOS)
            NSImage(size: NSSize(width: glyph.size, height: glyph.size))
            #else
            UIImage()
            #endif
        }
    }
}
