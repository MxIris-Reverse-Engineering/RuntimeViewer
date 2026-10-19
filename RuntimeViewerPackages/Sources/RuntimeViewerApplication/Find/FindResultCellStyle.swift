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
    // MARK: - Sizes

    /// The sizes a row is drawn at. The Find navigator's are Xcode's; the
    /// Inspector's References tab lists the same cross-reference rows a size
    /// down, beside text of its own set in the small system font. A hit's line
    /// keeps the navigator's fonts: only the navigator lists hits.
    public struct Metrics {
        /// The icon's frame, and the size a type's badge is drawn at. The
        /// glyphs below keep their own point size inside it and are scaled
        /// down only when they do not fit.
        public let iconSize: CGFloat

        /// A name: a type's, a function's.
        let titleFont: NSFont

        /// What follows a name: the image it is in, and for a cross-reference
        /// how many references it stands for and how sure they are.
        let subtitleFont: NSFont

        /// The Find navigator's: 16-point icons and 13-point text, as Xcode
        /// draws its rows.
        public static let navigator = Metrics(iconSize: 16, fontSize: 13)

        /// The Inspector's: 11-point text, the small system font the rest of
        /// the tab is set in, and 14-point icons, as tall as a line of it.
        public static let inspector = Metrics(iconSize: 14, fontSize: NSFont.smallSystemFontSize)

        private init(iconSize: CGFloat, fontSize: CGFloat) {
            self.iconSize = iconSize
            self.titleFont = .systemFont(ofSize: fontSize, weight: .medium)
            self.subtitleFont = .systemFont(ofSize: fontSize)
        }
    }

    // MARK: - Icons

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
    static func crossReferenceIcon(for root: FindCrossReferenceRoot, metrics: Metrics) -> NSImage? {
        switch root {
        case .member(let member, _):
            memberBadge(for: member, size: metrics.iconSize)
        case .function(let function):
            functionBadge(for: function, size: metrics.iconSize)
        case .type(let object):
            RuntimeObjectIcon.icon(for: object.kind, size: metrics.iconSize)
        }
    }

    /// A cross-reference row's icon. Xcode draws the symbol's kind, and swaps in
    /// a recursion badge for a call that came back around
    /// (`function_recursive` / `method_recursive`).
    static func crossReferenceIcon(for row: FindCrossReferenceRow, metrics: Metrics) -> NSImage? {
        if row.isRecursive {
            return recursiveCallIcon
        }
        let size = metrics.iconSize
        switch row.item {
        case .function(let function):
            return functionBadge(for: function, size: size)
        case .target(.selector):
            return badge("M", color: .orange, size: size)
        case .target(.importedSymbol(let name)):
            return languageBadge(for: RuntimeFunctionLanguage(symbol: name), size: size)
        case .target(.type(_, let object?)):
            return RuntimeObjectIcon.icon(for: object.kind, size: size)
        case .target(.type(_, nil)):
            return badge("T", color: .gray, size: size)
        case .target(.function(let function)):
            return functionBadge(for: function, size: size)
        case .target(.indirect), .target(.unrecognizedCode):
            return unresolvedIcon
        case .image(let path):
            // As the Report navigator draws an image.
            return path.contains(".framework/") ? RuntimeImageNode.frameworkIcon : RuntimeImageNode.imageIcon
        case .unnamedFunctions:
            return languageBadge(for: nil, size: size)
        case .loading:
            return loadingIcon
        case .failure:
            return failureIcon
        }
    }

    /// `M` for a method, `P` for a property or variable — orange on the
    /// Objective-C side and blue on the Swift side, the colours the type badges
    /// use.
    private static func memberBadge(for member: RuntimeMemberReference, size: CGFloat) -> NSImage? {
        let color: IDEIconColor = member.kind.isObjC ? .orange : .blue
        switch member.kind {
        case .objcProperty, .swiftVariable, .swiftField, .objcIvar:
            return badge("P", color: color, size: size)
        case .swiftEnumCase:
            return badge("E", color: color, size: size)
        case .objcMethod, .swiftFunction, .swiftInitializer, .swiftSubscript:
            return badge("M", color: color, size: size)
        }
    }

    /// A member's badge; otherwise the badge of the language its name tells.
    private static func functionBadge(for function: RuntimeFunctionReference, size: CGFloat) -> NSImage? {
        if let member = function.member {
            return memberBadge(for: member, size: size)
        }
        return languageBadge(for: function.language, size: size)
    }

    /// A function's badge by its language, in the colours the member badges
    /// use: `f` in blue for Swift, `M` in orange for an Objective-C method, `f`
    /// in green for C and C++, and in grey for a function nothing names.
    private static func languageBadge(for language: RuntimeFunctionLanguage?, size: CGFloat) -> NSImage? {
        switch language {
        case .swift?: badge("f", color: .blue, size: size)
        case .objectiveC?: badge("M", color: .orange, size: size)
        case .cOrCPlusPlus?: badge("f", color: .green, size: size)
        case nil: badge("f", color: .gray, size: size)
        }
    }

    /// The disclosure the Inspector's References tab draws on the row
    /// gathering a section's unnamed functions, which has no outline to draw
    /// one: pointing right while the row is collapsed, down while expanded.
    static func disclosureIcon(isExpanded: Bool) -> NSImage? {
        isExpanded ? expandedDisclosureIcon : collapsedDisclosureIcon
    }

    private static let collapsedDisclosureIcon: NSImage? = SFSymbols(systemName: .chevronRight, pointSize: 10, weight: .semibold).nsImage

    private static let expandedDisclosureIcon: NSImage? = SFSymbols(systemName: .chevronDown, pointSize: 10, weight: .semibold).nsImage

    private static func badge(_ text: String, color: IDEIconColor, size: CGFloat) -> NSImage? {
        RuntimeObjectIcon.icon(text: text, color: color, size: size)
    }

    static let recursiveCallIcon: NSImage? = SFSymbols(systemName: .arrowTriangle2Circlepath, pointSize: 12, weight: .regular).nsImage

    static let loadingIcon: NSImage? = SFSymbols(systemName: .hourglass, pointSize: 12, weight: .regular).nsImage

    static let failureIcon: NSImage? = SFSymbols(systemName: .exclamationmarkTriangle, pointSize: 12, weight: .regular).nsImage

    // MARK: - Type Rows

    /// A type's name, in `Metrics.titleFont`.
    static let titleColor: NSColor = .labelColor

    /// The image the type is in, after its name, in `Metrics.subtitleFont`.
    static let subtitleColor: NSColor = .secondaryLabelColor

    /// What sits between the name and the image.
    static let subtitleSeparator = "  "

    /// An unresolved relationship node's name, set in `Metrics.titleFont`.
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
