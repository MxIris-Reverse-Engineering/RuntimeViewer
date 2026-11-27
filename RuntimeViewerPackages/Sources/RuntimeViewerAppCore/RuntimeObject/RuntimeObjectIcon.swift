import Foundation
import RuntimeViewerCore

public enum RuntimeObjectIcon {
    #if os(macOS)
    public static let defaultIconSize: CGFloat = 18
    #else
    public static let defaultIconSize: CGFloat = 24
    #endif

    public static let defaultIconStyle: Glyph.Style = .simple

    /// What an object's icon shows: a short text on a coloured badge, the way Xcode marks a symbol's
    /// kind. This module only picks the glyph; RuntimeViewerAppUI draws it (`RuntimeObjectIconRendering`).
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
        // Green, as the C structs and unions are and as Find badges a C or
        // C++ function: the C family.
        case .cPlusPlus(.class):
            return ("C", .green)
        // A template's specializations gathered under its name; green like
        // the classes it holds, so the blue T of a Swift typealias stays apart.
        case .cPlusPlus(.classTemplate):
            return ("T", .green)
        case .cPlusPlus(.namespace):
            return ("N", .green)

        default:
            return ("?", .gray)
        }
    }

    /// The glyph of a kind of runtime object; RuntimeViewerAppUI draws it (`RuntimeObjectIcon.icon(for:)`).
    public static func glyph(for kind: RuntimeObjectKind, size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> Glyph {
        let (text, color) = glyphContent(for: kind)
        return Glyph(text: text, color: color, style: style, size: size)
    }

    /// A letter badge drawn the way an object's glyph is, for what is not an object: a Find row's
    /// member or function, a type that did not resolve.
    public static func glyph(text: String, color: Glyph.Color, size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> Glyph {
        Glyph(text: text, color: color, style: style, size: size)
    }

    /// The badge of a generic type.
    public static func genericGlyph(size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> Glyph {
        glyph(text: "G", color: .teal, size: size, style: style)
    }

    public static let tooltipForGeneric = "Generic Type"

    /// The badge of a specialization of a generic type.
    public static func specializedGlyph(size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> Glyph {
        glyph(text: "Sp", color: .pink, size: size, style: style)
    }

    public static let tooltipForSpecialized = "Specialized Generic Type"

    /// The badge for an Objective-C class implemented in Swift through
    /// SE-0436's `@objc @implementation extension`. Pink `C` against the blue
    /// `C` a bridged Swift class gets, because the two say different things:
    /// a bridged class is a Swift class the ObjC runtime can see, while this
    /// one is a real ObjC class whose header is still ObjC and whose bodies
    /// happen to be Swift.
    public static func objcImplementationGlyph(size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> Glyph {
        glyph(text: "C", color: .pink, size: size, style: style)
    }

    /// Spells out what `glyph(for: kind)` cannot: an Objective-C and a Swift
    /// class are both `C`, told apart by colour alone, and every Swift
    /// extension and conformance is `Ex`.
    public static func tooltip(for kind: RuntimeObjectKind) -> String {
        kind.description
    }

    /// The badge that sits beside `glyph(for: object.kind)`: the other face of a
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
    public static func secondaryGlyph(for object: RuntimeObject, size: CGFloat = Self.defaultIconSize, style: Glyph.Style = Self.defaultIconStyle) -> Glyph? {
        switch secondaryBadge(for: object) {
        case .objcImplementation:
            return objcImplementationGlyph(size: size, style: style)
        case .swiftClass:
            return glyph(for: .swift(.type(.class)), size: size, style: style)
        case .swiftProtocol:
            return glyph(for: .swift(.type(.protocol)), size: size, style: style)
        case .objcClass:
            return glyph(for: .objc(.type(.class)), size: size, style: style)
        case .objcProtocol:
            return glyph(for: .objc(.type(.protocol)), size: size, style: style)
        case nil:
            return nil
        }
    }

    /// The tooltip of `secondaryGlyph(for:)`, `nil` exactly when that is. The
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
