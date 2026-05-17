#if os(macOS)
import AppKit
#else
import UIKit
#endif

import UIFoundation
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures

extension RuntimeImageLoadState: @retroactive CaseAccessible {}

#if canImport(UIKit)

extension UIColor {
    public static var labelColor: UIColor {
        .label
    }

    public static var secondaryLabelColor: UIColor {
        .secondaryLabel
    }

    public static var tertiaryLabelColor: UIColor {
        .tertiaryLabel
    }

    public static var quaternaryLabelColor: UIColor {
        .quaternaryLabel
    }
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
    public static let frameworkIcon: NSUIImage = SFSymbols(systemName: .latch2Case).nsuiImgae

    public static let bundleIcon: NSUIImage = SFSymbols(systemName: .shippingbox).nsuiImgae

    public static let imageIcon: NSUIImage = SFSymbols(systemName: .doc).nsuiImgae

    public static let folderIcon: NSUIImage = SFSymbols(systemName: .folder).nsuiImgae

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

extension NSUIColor {
    public convenience init(light: NSUIColor, dark: NSUIColor) {
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
