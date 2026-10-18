#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import UIFoundation
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import RuntimeViewerUI

/// Every font, colour and icon a Find result row is drawn with, so tuning the
/// rows means changing a value here and nowhere else. `FindResultNode` builds
/// each row's appearance from these; `FindResultCellView` sizes and tints its
/// icon from them.
public enum FindResultCellStyle {
    // MARK: - Icons

    /// The icon's frame, and the size a type's badge is drawn at. The glyphs
    /// below keep their own point size inside it and are scaled down only when
    /// they do not fit.
    public static let iconSize: CGFloat = 16

    /// Xcode's match rows carry three horizontal lines in a rounded square.
    static let matchIcon: NSImage? = SFSymbols(systemName: .textAlignleft, pointSize: 13, weight: .regular).nsImage

    /// Xcode draws that glyph at 45 %.
    static let matchIconAlpha: CGFloat = 0.45

    /// A relationship node no indexed image defines.
    static let unresolvedIcon: NSImage? = SFSymbols(systemName: .questionmarkSquare, pointSize: 13, weight: .regular).nsImage

    static let unresolvedIconAlpha: CGFloat = 0.45

    /// Tints the glyphs; a type's badge is drawn in its own colours and
    /// ignores it.
    public static let iconTintColor: NSColor = .secondaryLabelColor

    public static let unresolvedIconTintColor: NSColor = .tertiaryLabelColor

    // MARK: - Cross-Reference Rows

    /// A cross-reference root's icon: its member's badge, or its type's.
    static func crossReferenceIcon(for root: FindCrossReferenceRoot) -> NSImage? {
        switch root {
        case .member(let member, _):
            memberBadge(for: member)
        case .function(let function):
            functionBadge(for: function)
        case .type(let object):
            RuntimeObjectIcon.icon(for: object.kind, size: iconSize)
        }
    }

    /// A cross-reference row's icon. Xcode draws the symbol's kind, and swaps in
    /// a recursion badge for a call that came back around
    /// (`function_recursive` / `method_recursive`).
    static func crossReferenceIcon(for row: FindCrossReferenceRow) -> NSImage? {
        if row.isRecursive {
            return recursiveCallIcon
        }
        switch row.item {
        case .function(let function):
            return functionBadge(for: function)
        case .target(.selector):
            return badge("M", color: .orange)
        case .target(.importedSymbol):
            return badge("f", color: .gray)
        case .target(.type(_, let object?)):
            return RuntimeObjectIcon.icon(for: object.kind, size: iconSize)
        case .target(.type(_, nil)):
            return badge("T", color: .gray)
        case .target(.function(let function)):
            return functionBadge(for: function)
        case .target(.indirect), .target(.unrecognizedCode):
            return unresolvedIcon
        case .image(let path):
            // As the Report navigator draws an image.
            return path.contains(".framework/") ? RuntimeImageNode.frameworkIcon : RuntimeImageNode.imageIcon
        case .loading:
            return loadingIcon
        case .failure:
            return failureIcon
        }
    }

    /// `M` for a method, `P` for a property or variable — orange on the
    /// Objective-C side and blue on the Swift side, the colours the type badges
    /// use.
    private static func memberBadge(for member: RuntimeMemberReference) -> NSImage? {
        let color: IDEIconColor = member.kind.isObjC ? .orange : .blue
        switch member.kind {
        case .objcProperty, .swiftVariable, .swiftField, .objcIvar:
            return badge("P", color: color)
        case .swiftEnumCase:
            return badge("E", color: color)
        case .objcMethod, .swiftFunction, .swiftInitializer, .swiftSubscript:
            return badge("M", color: color)
        }
    }

    /// A member's badge, `f` in green for a named function of no type, and
    /// in grey for one nothing names.
    private static func functionBadge(for function: RuntimeFunctionReference) -> NSImage? {
        if let member = function.member {
            return memberBadge(for: member)
        }
        return badge("f", color: function.displayName == nil ? .gray : .green)
    }

    private static func badge(_ text: String, color: IDEIconColor) -> NSImage? {
        RuntimeObjectIcon.icon(text: text, color: color, size: iconSize)
    }

    static let recursiveCallIcon: NSImage? = SFSymbols(systemName: .arrowTriangle2Circlepath, pointSize: 12, weight: .regular).nsImage

    static let loadingIcon: NSImage? = SFSymbols(systemName: .hourglass, pointSize: 12, weight: .regular).nsImage

    static let failureIcon: NSImage? = SFSymbols(systemName: .exclamationmarkTriangle, pointSize: 12, weight: .regular).nsImage

    // MARK: - Type Rows

    /// A type's name.
    static let titleFont: NSFont = .systemFont(ofSize: 13, weight: .medium)

    static let titleColor: NSColor = .labelColor

    /// The image the type is in, after its name.
    static let subtitleFont: NSFont = .systemFont(ofSize: 13)

    static let subtitleColor: NSColor = .secondaryLabelColor

    /// What sits between the name and the image.
    static let subtitleSeparator = "  "

    /// An unresolved relationship node's name, set in `titleFont`.
    static let unresolvedTitleColor: NSColor = .secondaryLabelColor

    /// One line, cut at its end with an ellipsis. A title is an attributed string, which AppKit
    /// breaks by its own paragraph style: the label's `lineBreakMode` applies to plain strings
    /// alone (`NSCell.wraps`). Without it a title too long for its row wrapped by word, and the
    /// row drew its first line only — `-` for an Objective-C method.
    static let titleParagraphStyle: NSParagraphStyle = {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        return paragraphStyle
    }()

    // MARK: - Hit Rows

    /// A hit's line, or a member's declaration, outside the hit itself.
    static let hitLineFont: NSFont = .systemFont(ofSize: 13)

    static let hitLineColor: NSColor = .filterResultNonMatchingTextColor

    /// The hit itself.
    static let emphasisFont: NSFont = .systemFont(ofSize: 13, weight: .bold)

    static let emphasisColor: NSColor = .filterResultMatchingTextColor
}
#endif
