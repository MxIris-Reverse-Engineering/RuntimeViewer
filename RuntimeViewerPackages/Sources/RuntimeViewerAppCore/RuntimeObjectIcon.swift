#if os(macOS)
import AppKit
#else
import UIKit
#endif

import Dependencies
import RuntimeViewerCore

public enum RuntimeObjectIcon {
    #if os(macOS)
    public static let defaultIconSize: CGFloat = 18
    #else
    public static let defaultIconSize: CGFloat = 24
    #endif

    public static let defaultIconStyle: Glyph.Style = .simple

    /// What an object's icon shows: a short text on a coloured badge, the way Xcode marks a symbol's
    /// kind. This module only picks the glyph; `RuntimeObjectIconRendering` draws it.
    public struct Glyph: Hashable, Sendable {
        /// The colours of UIFoundation's `IDEIconColor`, under the same names.
        public enum Color: Hashable, Sendable {
            case monochrome
            case blue
            case brown
            case gray
            case green
            case orange
            case pink
            case purple
            case red
            case teal
            case yellow
            case indigo
            case mint
            case cyan
        }

        /// The styles of UIFoundation's `IDEIconStyle`, under the same names.
        public enum Style: Hashable, Sendable {
            case `default`
            case outline
            case simple
            case simpleHighlighted
        }

        public var text: String
        public var color: Color
        public var style: Style
        public var size: CGFloat

        public init(text: String, color: Color, style: Style, size: CGFloat) {
            self.text = text
            self.color = color
            self.style = style
            self.size = size
        }
    }

    private static func glyphContent(for kind: RuntimeObjectKind) -> (text: String, color: Glyph.Color) {
        switch kind {
        case .c(let kind):
            switch kind {
            case .struct: return ("S", .green)
            case .union: return ("U", .green)
            }

        case .objc(.type(let kind)):
            switch kind {
            case .class: return ("C", .orange)
            case .protocol: return ("Pr", .purple)
            }

        case .objc(.category(.class)):
            return ("Ex", .orange)

        case .swift(.type(let kind)):
            switch kind {
            case .enum: return ("E", .blue)
            case .struct: return ("S", .blue)
            case .class: return ("C", .blue)
            case .protocol: return ("Pr", .blue)
            case .typeAlias: return ("T", .blue)
            }

        case .swift(.extension(_)),
             .swift(.conformance(_)):
            return ("Ex", .blue)

        default:
            return ("?", .gray)
        }
    }

    /// The glyph `icon(for: kind)` draws.
    public static func glyph(for kind: RuntimeObjectKind, size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> Glyph {
        let (text, color) = glyphContent(for: kind)
        return Glyph(text: text, color: color, style: style, size: size)
    }

    public static func icon(text: String, color: Glyph.Color, size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> NSUIImage {
        @Dependency(\.runtimeObjectIconRendering) var runtimeObjectIconRendering
        return runtimeObjectIconRendering.image(for: Glyph(text: text, color: color, style: style, size: size))
    }

    public static func iconForGeneric(size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> NSUIImage {
        return icon(text: "G", color: .teal, size: size, style: style)
    }

    public static let tooltipForGeneric = "Generic Type"

    public static func iconForSpecialized(size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> NSUIImage {
        return icon(text: "Sp", color: .pink, size: size, style: style)
    }

    public static let tooltipForSpecialized = "Specialized Generic Type"

    /// The badge for an Objective-C class implemented in Swift through
    /// SE-0436's `@objc @implementation extension`. Pink `C` against the blue
    /// `C` a bridged Swift class gets, because the two say different things:
    /// a bridged class is a Swift class the ObjC runtime can see, while this
    /// one is a real ObjC class whose header is still ObjC and whose bodies
    /// happen to be Swift.
    public static func iconForObjCImplementation(size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> NSUIImage {
        return icon(text: "C", color: .pink, size: size, style: style)
    }

    public static func icon(for kind: RuntimeObjectKind, size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> NSUIImage {
        let (text, color) = glyphContent(for: kind)
        return icon(text: text, color: color, size: size, style: style)
    }

    /// Spells out what `icon(for: kind)` cannot: an Objective-C and a Swift
    /// class are both `C`, told apart by colour alone, and every Swift
    /// extension and conformance is `Ex`.
    public static func tooltip(for kind: RuntimeObjectKind) -> String {
        kind.description
    }

    /// The badge that sits beside `icon(for: object.kind)`: the other face of a
    /// class or protocol both lists show, so the choice is made here, once,
    /// rather than at each call site. A bridged class's two faces badge each
    /// other — the Objective-C entry gets a blue Swift `C` (`isSwiftClass`),
    /// the Swift entry an orange Objective-C `C` (`isObjCClass`). An `@objc
    /// @implementation` pair carries the pink `C` on both faces, the class and
    /// its extension. On the Objective-C side the first two are mutually
    /// exclusive — the Swift bit of a class data pointer is either set or clear.
    /// An `@objc` protocol declared in Swift is badged the way a bridged class
    /// is: a blue Swift `P` on its Objective-C entry (`isSwiftProtocol`), a
    /// purple Objective-C `P` on its Swift entry (`isObjCProtocol`).
    public static func secondaryIcon(for object: RuntimeObject, size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> NSUIImage? {
        switch secondaryBadge(for: object) {
        case .objcImplementation:
            return iconForObjCImplementation(size: size, style: style)
        case .swiftClass:
            return icon(for: .swift(.type(.class)), size: size, style: style)
        case .swiftProtocol:
            return icon(for: .swift(.type(.protocol)), size: size, style: style)
        case .objcClass:
            return icon(for: .objc(.type(.class)), size: size, style: style)
        case .objcProtocol:
            return icon(for: .objc(.type(.protocol)), size: size, style: style)
        case nil:
            return nil
        }
    }

    /// The tooltip of `secondaryIcon(for:)`, `nil` exactly when that is. The
    /// pink badge reads differently on its two faces: the Objective-C class is
    /// implemented in Swift, the Swift extension implements it.
    public static func secondaryTooltip(for object: RuntimeObject) -> String? {
        switch secondaryBadge(for: object) {
        case .objcImplementation:
            return object.kind.isObjC
                ? "Implemented in Swift (@objc @implementation)"
                : "Implements an Objective-C Class (@objc @implementation)"
        case .swiftClass:
            return "Also Listed as a Swift Class"
        case .swiftProtocol:
            return "Also Listed as a Swift Protocol"
        case .objcClass:
            return "Also Listed as an Objective-C Class"
        case .objcProtocol:
            return "Also Listed as an Objective-C Protocol"
        case nil:
            return nil
        }
    }

    private enum SecondaryBadge {
        case objcImplementation
        case swiftClass
        case swiftProtocol
        case objcClass
        case objcProtocol
    }

    /// The one place that orders the flags, so the icon and its tooltip can
    /// never pick different badges. The implementation flag goes first: the
    /// binary never sets it together with `isSwiftClass`, but if something
    /// upstream ever does, painting the blue badge over the pink one would be
    /// the harder bug to spot.
    private static func secondaryBadge(for object: RuntimeObject) -> SecondaryBadge? {
        if object.properties.contains(.isObjCImplementation) {
            return .objcImplementation
        }
        if object.properties.contains(.isSwiftClass) {
            return .swiftClass
        }
        if object.properties.contains(.isSwiftProtocol) {
            return .swiftProtocol
        }
        if object.properties.contains(.isObjCClass) {
            return .objcClass
        }
        if object.properties.contains(.isObjCProtocol) {
            return .objcProtocol
        }
        return nil
    }
}

// MARK: - Drawing

/// Draws an object's icon. RuntimeViewerAppUI's live value draws it the way Xcode draws a symbol's
/// kind, with UIFoundation's `IDEIcon`; this module only picks the glyph.
///
/// A renderer gives back the same image for the same glyph, as the icons always have: a cell's
/// `Appearance` compares its icons, and a row republishes only when they differ.
public protocol RuntimeObjectIconRendering: AnyObject, Sendable {
    func image(for glyph: RuntimeObjectIcon.Glyph) -> NSUIImage
}

/// RuntimeViewerAppUI adds the `DependencyKey` conformance with the live value; this module declares
/// the interface and the value tests get (swift-dependencies' "Separating interface and implementation").
package enum RuntimeObjectIconRenderingKey: TestDependencyKey {
    package static let testValue: any RuntimeObjectIconRendering = BlankRuntimeObjectIconRenderer()
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
