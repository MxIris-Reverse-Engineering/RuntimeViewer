#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
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

    // MARK: - Type Rows

    /// A type's name.
    static let titleFont: NSFont = .systemFont(ofSize: 14)

    static let titleColor: NSColor = .labelColor

    /// The image the type is in, after its name.
    static let subtitleFont: NSFont = .systemFont(ofSize: 11)

    static let subtitleColor: NSColor = .secondaryLabelColor

    /// What sits between the name and the image.
    static let subtitleSeparator = "  "

    /// An unresolved relationship node's name, set in `titleFont`.
    static let unresolvedTitleColor: NSColor = .secondaryLabelColor

    // MARK: - Hit Rows

    /// A hit's line, or a member's declaration, outside the hit itself.
    static let hitLineFont: NSFont = .systemFont(ofSize: 13)

    static let hitLineColor: NSColor = .filterResultNonMatchingTextColor

    /// The hit itself.
    static let emphasisFont: NSFont = .systemFont(ofSize: 13, weight: .bold)

    static let emphasisColor: NSColor = .filterResultMatchingTextColor
}
#endif
