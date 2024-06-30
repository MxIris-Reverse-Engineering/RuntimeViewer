#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures

extension RuntimeObjectType {
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    private static let iconSize: CGFloat = 16
    #endif

    #if canImport(UIKit)
    private static let iconSize: CGFloat = 24
    #endif

    public static let classIcon = IDEIcon("C", color: .yellow, style: .default, size: iconSize).image
    public static let protocolIcon = IDEIcon("Pr", color: .purple, style: .default, size: iconSize).image
//    public static let classIcon = SFSymbol(systemName: .cSquare).nsuiImage
//    public static let protocolIcon = SFSymbol(systemName: .pSquare).nsuiImage

    public var icon: NSUIImage {
        switch self {
        case .class: return Self.classIcon
        case .protocol: return Self.protocolIcon
        }
    }
}

extension RuntimeObjectType: Comparable {
    public static func < (lhs: RuntimeObjectType, rhs: RuntimeObjectType) -> Bool {
        switch (lhs, rhs) {
        case (.class, .protocol):
            return true
        case (.protocol, .class):
            return false
        case let (.class(className1), .class(className2)):
            return className1 < className2
        case let (.protocol(protocolName1), .protocol(protocolName2)):
            return protocolName1 < protocolName2
        }
    }
}

extension RuntimeImageLoadState: CaseAccessible {}

#if canImport(UIKit)

extension UIColor {
    static var labelColor: UIColor { .label }
}

#endif

extension RuntimeNamedNode: Sequence {
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
    public static let frameworkIcon = SFSymbol(systemName: .latch2Case).nsuiImage

    public static let bundleIcon = SFSymbol(systemName: .shippingbox).nsuiImage

    public static let imageIcon = SFSymbol(systemName: .doc).nsuiImage

    public static let folderIcon = SFSymbol(systemName: .folder).nsuiImage

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

extension SFSymbol {
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
