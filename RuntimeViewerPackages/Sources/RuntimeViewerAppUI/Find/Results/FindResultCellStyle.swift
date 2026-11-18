#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import RuntimeViewerAppCore

/// Every font and colour a Find result row is drawn with, so tuning the
/// rows means changing a value here and nowhere else. `FindResultNode` (in
/// RuntimeViewerAppCore) describes each row in roles; `RowTextStyle.findResult(_:)`
/// draws the roles in these, and `FindResultCellView` sizes and tints its
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

    // MARK: - Icon Tints

    /// Tints the glyphs; a type's badge is drawn in its own colours and
    /// ignores it. Which icon a row shows is `FindResultIcon`'s.
    public static let iconTintColor: NSColor = .secondaryLabelColor

    public static let unresolvedIconTintColor: NSColor = .tertiaryLabelColor

    // MARK: - Type Rows

    /// A type's name, in `Metrics.titleFont`.
    static let titleColor: NSColor = .labelColor

    /// The image the type is in, after its name, in `Metrics.subtitleFont`.
    static let subtitleColor: NSColor = .secondaryLabelColor


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
