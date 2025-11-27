#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures

extension RuntimeObjectKind {
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    private static let iconSize: CGFloat = 18
    #endif

    #if canImport(UIKit)
    private static let iconSize: CGFloat = 24
    #endif

    private static let iconStyle: IDEIconStyle = .simple

    public static let objcClassIcon = IDEIcon("C", color: .yellow, style: iconStyle, size: iconSize).image
    public static let objcProtocolIcon = IDEIcon("Pr", color: .purple, style: iconStyle, size: iconSize).image

    public static let swiftEnumIcon = IDEIcon("E", color: .blue, style: iconStyle, size: iconSize).image
    public static let swiftStructIcon = IDEIcon("S", color: .blue, style: iconStyle, size: iconSize).image
    public static let swiftClassIcon = IDEIcon("C", color: .blue, style: iconStyle, size: iconSize).image
    public static let swiftProtocolIcon = IDEIcon("Pr", color: .blue, style: iconStyle, size: iconSize).image
    public static let swiftExtensionIcon = IDEIcon("Ex", color: .blue, style: iconStyle, size: iconSize).image
    public static let swiftTypeAliasIcon = IDEIcon("T", color: .blue, style: iconStyle, size: iconSize).image

    public var icon: NSUIImage {
        switch self {
        case .objc(.type(let kindOfObjC)),
             .objc(.category(let kindOfObjC)):
            switch kindOfObjC {
            case .class: return Self.objcClassIcon
            case .protocol: return Self.objcProtocolIcon
            }
        case .swift(.type(let kindOfSwift)):
            switch kindOfSwift {
            case .enum: return Self.swiftEnumIcon
            case .struct: return Self.swiftStructIcon
            case .class: return Self.swiftClassIcon
            case .protocol: return Self.swiftProtocolIcon
            case .typeAlias: return Self.swiftTypeAliasIcon
            }
        case .swift(.extension(_)),
             .swift(.conformance(_)):
            return Self.swiftExtensionIcon
        default:
            fatalError()
        }
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
    public static let frameworkIcon = SFSymbols(systemName: .latch2Case)

    public static let bundleIcon = SFSymbols(systemName: .shippingbox)

    public static let imageIcon = SFSymbols(systemName: .doc)

    public static let folderIcon = SFSymbols(systemName: .folder)

    public var icon: NSUIImage {
        #if os(macOS)
        symbol
            .hierarchicalColor(.controlAccentColor)
            .nsuiImgae
        #else
        symbol
            .nsuiImgae
        #endif
    }

    private var symbol: SFSymbols {
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
}

extension NSUIColor {
    convenience init(light: NSUIColor, dark: NSUIColor) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        self.init(name: nil) { appearance in
            appearance.isLight ? light : dark
        }
        #endif

        #if canImport(UIKit)
        self.init { traitCollection in
            traitCollection.userInterfaceStyle == .light ? light : dark
        }
        #endif
    }
}
