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

    public static func iconForSpecialized(size: CGFloat = Self.defaultIconSize, style: IDEIconStyle = Self.defaultIconStyle) -> NSUIImage {
        return icon(text: "Sp", color: .pink, size: size, style: style)
    }

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

    /// The badge that sits beside `icon(for: object.kind)`. An ObjC class
    /// reaches it two ways and they are mutually exclusive — the Swift bit of
    /// a class data pointer is either set (a bridged Swift class, blue `C`)
    /// or clear (possibly an `@objc @implementation`, pink `C`) — so the
    /// choice is made here, once, rather than at each call site.
    public static func secondaryIcon(for object: RuntimeObject, size: CGFloat = Self.defaultIconSize, style: IDEIconStyle = Self.defaultIconStyle) -> NSUIImage? {
        if object.properties.contains(.isObjCImplementation) {
            return iconForObjCImplementation(size: size, style: style)
        }
        if object.properties.contains(.isSwiftClass) {
            return icon(for: .swift(.type(.class)), size: size, style: style)
        }
        return nil
    }
}
