#if os(macOS)
import AppKit
#else
import UIKit
#endif

import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures

//extension RuntimeObjectKind {
//    #if os(macOS)
//    private static let iconSize: CGFloat = 18
//    #else
//    private static let iconSize: CGFloat = 24
//    #endif
//
//    private static let iconStyle: IDEIconStyle = .simple
//
//    public static let cStructIcon = IDEIcon("S", color: .green, style: iconStyle, size: iconSize).image
//    public static let cUnionIcon = IDEIcon("U", color: .green, style: iconStyle, size: iconSize).image
//    
//    public static let objcClassIcon = IDEIcon("C", color: .yellow, style: iconStyle, size: iconSize).image
//    public static let objcProtocolIcon = IDEIcon("Pr", color: .purple, style: iconStyle, size: iconSize).image
//    public static let objcCategoryIcon = IDEIcon("Ex", color: .yellow, style: iconStyle, size: iconSize).image
//
//    public static let swiftEnumIcon = IDEIcon("E", color: .blue, style: iconStyle, size: iconSize).image
//    public static let swiftStructIcon = IDEIcon("S", color: .blue, style: iconStyle, size: iconSize).image
//    public static let swiftClassIcon = IDEIcon("C", color: .blue, style: iconStyle, size: iconSize).image
//    public static let swiftProtocolIcon = IDEIcon("Pr", color: .blue, style: iconStyle, size: iconSize).image
//    public static let swiftExtensionIcon = IDEIcon("Ex", color: .blue, style: iconStyle, size: iconSize).image
//    public static let swiftTypeAliasIcon = IDEIcon("T", color: .blue, style: iconStyle, size: iconSize).image
//
//    public var icon: NSUIImage {
//        switch self {
//        case .c(let kind):
//            switch kind {
//            case .struct: return Self.cStructIcon
//            case .union: return Self.cUnionIcon
//            }
//        case .objc(.type(let kind)):
//            switch kind {
//            case .class: return Self.objcClassIcon
//            case .protocol: return Self.objcProtocolIcon
//            }
//        case .objc(.category(.class)):
//            return Self.objcCategoryIcon
//        case .swift(.type(let kind)):
//            switch kind {
//            case .enum: return Self.swiftEnumIcon
//            case .struct: return Self.swiftStructIcon
//            case .class: return Self.swiftClassIcon
//            case .protocol: return Self.swiftProtocolIcon
//            case .typeAlias: return Self.swiftTypeAliasIcon
//            }
//        case .swift(.extension(_)),
//             .swift(.conformance(_)):
//            return Self.swiftExtensionIcon
//        default:
//            fatalError()
//        }
//    }
//}

extension RuntimeObjectKind {

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

//    @MainActor
    private static var iconCache: [IconCacheKey: NSUIImage] = [:]

    private var iconSpec: (text: String, color: IDEIconColor) {
        switch self {
        case .c(let kind):
            switch kind {
            case .struct: return ("S", .green)
            case .union:  return ("U", .green)
            }
        
        case .objc(.type(let kind)):
            switch kind {
            case .class:    return ("C", .yellow)
            case .protocol: return ("Pr", .purple)
            }
            
        case .objc(.category(.class)):
            return ("Ex", .yellow)
            
        case .swift(.type(let kind)):
            switch kind {
            case .enum:      return ("E", .blue)
            case .struct:    return ("S", .blue)
            case .class:     return ("C", .blue)
            case .protocol:  return ("Pr", .blue)
            case .typeAlias: return ("T", .blue)
            }
            
        case .swift(.extension(_)),
             .swift(.conformance(_)):
            return ("Ex", .blue)
            
        default:
            return ("?", .gray)
        }
    }

//    @MainActor
    public func icon(size: CGFloat = Self.defaultIconSize, style: IDEIconStyle = Self.defaultIconStyle) -> NSUIImage {
        let spec = self.iconSpec
        
        let key = IconCacheKey(
            text: spec.text,
            color: spec.color,
            style: style,
            size: size
        )
        
        if let cachedImage = Self.iconCache[key] {
            return cachedImage
        }
        
        let image = IDEIcon(
            spec.text,
            color: spec.color,
            style: style,
            size: size
        ).image
        
        Self.iconCache[key] = image
        
        return image
    }

//    @MainActor
    public var icon: NSUIImage {
        return icon()
    }
}

extension RuntimeImageLoadState: @retroactive CaseAccessible {}

#if canImport(UIKit)

extension UIColor {
    static var labelColor: UIColor { .label }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
    static var tertiaryLabelColor: UIColor { .tertiaryLabel }
    static var quaternaryLabelColor: UIColor { .quaternaryLabel }
}

#endif

extension RuntimeImageNode: @retroactive Sequence {
    public func makeIterator() -> Iterator {
        return Iterator(node: self)
    }

    public struct Iterator: IteratorProtocol {
        var stack: [RuntimeImageNode] = []

        init(node: RuntimeImageNode) {
            self.stack = [node]
        }

        public mutating func next() -> RuntimeImageNode? {
            if let node = stack.popLast() {
                stack.append(contentsOf: node.children.reversed())
                return node
            }
            return nil
        }
    }
}

extension RuntimeImageNode {
    public static let frameworkIcon: NSUIImage = icon(for: SFSymbols(systemName: .latch2Case))

    public static let bundleIcon: NSUIImage = icon(for: SFSymbols(systemName: .shippingbox))

    public static let imageIcon: NSUIImage = icon(for: SFSymbols(systemName: .doc))

    public static let folderIcon: NSUIImage = icon(for: SFSymbols(systemName: .folder))

    public var icon: NSUIImage {
        if name.hasSuffix("framework") {
            Self.frameworkIcon
        } else if name.hasSuffix("bundle") {
            Self.bundleIcon
        } else if isLeaf {
            Self.imageIcon
        } else {
            Self.folderIcon
        }
    }

    private static func icon(for symbol: SFSymbols) -> NSUIImage {
        #if os(macOS)
        symbol
            .nsuiImgae
        #else
        symbol
            .nsuiImgae
        #endif
    }
}

extension NSUIColor {
    convenience init(light: NSUIColor, dark: NSUIColor) {
        #if os(macOS)
        self.init(name: nil) { appearance in
            appearance.isLight ? light : dark
        }
        #else
        self.init { traitCollection in
            traitCollection.userInterfaceStyle == .light ? light : dark
        }
        #endif
    }
}

extension String {
    // MARK: - Index to Int Conversion

    /// Converts String.Index to Int (Integer offset).
    /// - Parameter index: The String.Index to convert.
    /// - Returns: The integer offset corresponding to the index.
    func integerIndex(of index: String.Index) -> Int {
        return distance(from: startIndex, to: index)
    }

    // MARK: - Int to Index Conversion

    /// Converts Int (Integer offset) to String.Index.
    /// - Parameter offset: The integer offset.
    /// - Returns: The corresponding String.Index, or nil if out of bounds.
    func index(at offset: Int) -> String.Index? {
        guard offset >= 0, offset <= count else { return nil }
        return index(startIndex, offsetBy: offset)
    }

    // MARK: - Range<String.Index> to Range<Int>

    /// Converts Range<String.Index> to Range<Int> (NSRange style).
    /// - Parameter range: The range of String.Index.
    /// - Returns: The corresponding Range<Int>.
    func integerRange(from range: Range<String.Index>) -> Range<Int> {
        let start = integerIndex(of: range.lowerBound)
        let end = integerIndex(of: range.upperBound)
        return start ..< end
    }

    // MARK: - Range<Int> to Range<String.Index>

    /// Converts Range<Int> to Range<String.Index>.
    /// - Parameter range: The range of integers.
    /// - Returns: The corresponding Range<String.Index>, or nil if indices are invalid.
    func indexRange(from range: Range<Int>) -> Range<String.Index>? {
        guard let start = index(at: range.lowerBound),
              let end = index(at: range.upperBound) else {
            return nil
        }
        return start ..< end
    }
}
