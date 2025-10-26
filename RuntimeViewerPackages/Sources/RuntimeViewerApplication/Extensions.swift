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
    private static let iconSize: CGFloat = 16
    #endif

    #if canImport(UIKit)
    private static let iconSize: CGFloat = 24
    #endif

    public static let objcClassIcon = IDEIcon("C", color: .yellow, style: .default, size: iconSize).image
    public static let objcProtocolIcon = IDEIcon("Pr", color: .purple, style: .default, size: iconSize).image

    public static let swiftEnumIcon = IDEIcon("E", color: .blue, style: .default, size: iconSize).image
    public static let swiftStructIcon = IDEIcon("S", color: .blue, style: .default, size: iconSize).image
    public static let swiftClassIcon = IDEIcon("C", color: .blue, style: .default, size: iconSize).image
    public static let swiftProtocolIcon = IDEIcon("Pr", color: .blue, style: .default, size: iconSize).image
    public static let swiftExtensionIcon = IDEIcon("Ex", color: .blue, style: .default, size: iconSize).image
    public static let swiftTypeAliasIcon = IDEIcon("T", color: .blue, style: .default, size: iconSize).image

//    public static let classIcon = SFSymbols(systemName: .cSquare).nsuiImage
//    public static let protocolIcon = SFSymbols(systemName: .pSquare).nsuiImage
    
    public var icon: NSUIImage {
        switch self {
        case .objc(let kindOfObjC):
            switch kindOfObjC {
            case .class: return Self.objcClassIcon
            case .protocol: return Self.objcProtocolIcon
            }
        case .swift(let kindOfSwift):
            switch kindOfSwift {
            case .enum: return Self.swiftEnumIcon
            case .struct: return Self.swiftStructIcon
            case .class: return Self.swiftClassIcon
            case .protocol: return Self.swiftProtocolIcon
            case .typeAlias: return Self.swiftTypeAliasIcon
            }
        case .swiftExtension:
            return Self.swiftExtensionIcon
        default:
            fatalError()
        }
    }
}

extension RuntimeObjectType: @retroactive Comparable {
    public static func < (lhs: RuntimeObjectType, rhs: RuntimeObjectType) -> Bool {
        switch (lhs, rhs) {
        case (.class, .protocol):
            return true
        case (.protocol, .class):
            return false
        case (.class(let className1), .class(let className2)):
            return className1 < className2
        case (.protocol(let protocolName1), .protocol(let protocolName2)):
            return protocolName1 < protocolName2
        }
    }
}

extension RuntimeImageLoadState: @retroactive CaseAccessible {}

#if canImport(UIKit)

extension UIColor {
    static var labelColor: UIColor { .label }
}

#endif

extension RuntimeNamedNode: @retroactive Sequence {
    public func makeIterator() -> Iterator {
        return Iterator(node: self)
    }

    public struct Iterator: IteratorProtocol {
        var stack: [RuntimeNamedNode] = []

        init(node: RuntimeNamedNode) {
            self.stack = [node]
        }

        public mutating func next() -> RuntimeNamedNode? {
            if let node = stack.popLast() {
                stack.append(contentsOf: node.children.reversed())
                return node
            }
            return nil
        }
    }
}


extension RuntimeNamedNode {
    public static let frameworkIcon = SFSymbols(systemName: .latch2Case).nsuiImage

    public static let bundleIcon = SFSymbols(systemName: .shippingbox).nsuiImage

    public static let imageIcon = SFSymbols(systemName: .doc).nsuiImage

    public static let folderIcon = SFSymbols(systemName: .folder).nsuiImage

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
}

extension SFSymbols {
    public var nsuiImage: NSUIImage {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return nsImage
        #endif

        #if canImport(UIKit)
        return uiImage
        #endif
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
