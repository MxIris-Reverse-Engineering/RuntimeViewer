#if os(macOS)
import AppKit
#else
import UIKit
#endif

import UIFoundation
import RuntimeViewerCore

public enum RuntimeObjectIcon {
    #if os(macOS)
    public static let defaultIconSize: CGFloat = 18
    #else
    public static let defaultIconSize: CGFloat = 24
    #endif

    public static let defaultIconStyle: IDEIconStyle = .simple

    private struct IconCacheKey: Hashable {
        let text: String
        let color: IDEIconColor
        let style: IDEIconStyle
        let size: CGFloat
    }

    private static var iconCache: [IconCacheKey: NSUIImage] = [:]

    private static func iconInfo(for kind: RuntimeObjectKind) -> (text: String, color: IDEIconColor) {
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

    public static func icon(text: String, color: IDEIconColor, size: CGFloat = Self.defaultIconSize, style: IDEIconStyle = Self.defaultIconStyle) -> NSUIImage {
        let key = IconCacheKey(
            text: text,
            color: color,
            style: style,
            size: size
        )

        if let cachedImage = Self.iconCache[key] {
            return cachedImage
        }

        let image = IDEIcon(
            text,
            color: color,
            style: style,
            size: size
        ).image

        Self.iconCache[key] = image

        return image
    }

    public static func iconForGeneric(size: CGFloat = Self.defaultIconSize, style: IDEIconStyle = Self.defaultIconStyle) -> NSUIImage {
        return icon(text: "G", color: .teal, size: size, style: style)
    }

    public static let tooltipForGeneric = "Generic Type"

    public static func iconForSpecialized(size: CGFloat = Self.defaultIconSize, style: IDEIconStyle = Self.defaultIconStyle) -> NSUIImage {
        return icon(text: "Sp", color: .pink, size: size, style: style)
    }

    public static let tooltipForSpecialized = "Specialized Generic Type"

    /// The badge for an Objective-C class implemented in Swift through
    /// SE-0436's `@objc @implementation extension`. Pink `C` against the blue
    /// `C` a bridged Swift class gets, because the two say different things:
    /// a bridged class is a Swift class the ObjC runtime can see, while this
    /// one is a real ObjC class whose header is still ObjC and whose bodies
    /// happen to be Swift.
    public static func iconForObjCImplementation(size: CGFloat = Self.defaultIconSize, style: IDEIconStyle = Self.defaultIconStyle) -> NSUIImage {
        return icon(text: "C", color: .pink, size: size, style: style)
    }

    public static func icon(for kind: RuntimeObjectKind, size: CGFloat = Self.defaultIconSize, style: IDEIconStyle = Self.defaultIconStyle) -> NSUIImage {
        let (text, color) = iconInfo(for: kind)
        return icon(text: text, color: color, size: size, style: style)
    }

    /// Spells out what `icon(for: kind)` cannot: an Objective-C and a Swift
    /// class are both `C`, told apart by colour alone, and every Swift
    /// extension and conformance is `Ex`.
    public static func tooltip(for kind: RuntimeObjectKind) -> String {
        kind.description
    }

    /// The badge that sits beside `icon(for: object.kind)`: the other face of a
    /// class both lists show, so the choice is made here, once, rather than at
    /// each call site. A bridged class's two faces badge each other — the
    /// Objective-C entry gets a blue Swift `C` (`isSwiftClass`), the Swift
    /// entry an orange Objective-C `C` (`isObjCClass`). An `@objc
    /// @implementation` pair carries the pink `C` on both faces, the class and
    /// its extension. On the Objective-C side the first two are mutually
    /// exclusive — the Swift bit of a class data pointer is either set or clear.
    public static func secondaryIcon(for object: RuntimeObject, size: CGFloat = Self.defaultIconSize, style: IDEIconStyle = Self.defaultIconStyle) -> NSUIImage? {
        switch secondaryBadge(for: object) {
        case .objcImplementation:
            return iconForObjCImplementation(size: size, style: style)
        case .swiftClass:
            return icon(for: .swift(.type(.class)), size: size, style: style)
        case .objcClass:
            return icon(for: .objc(.type(.class)), size: size, style: style)
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
        case .objcClass:
            return "Also Listed as an Objective-C Class"
        case nil:
            return nil
        }
    }

    private enum SecondaryBadge {
        case objcImplementation
        case swiftClass
        case objcClass
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
        if object.properties.contains(.isObjCClass) {
            return .objcClass
        }
        return nil
    }
}
