import AppKit

/// How the SourceEditor pane draws comment tags: capsules with a faint fill and a hairline in a
/// hue per kind of fact, the label in a shade of the same hue, and the value in a quietened text
/// colour. Worked out from the theme each time it is applied; notes take the comment colour.
///
/// Chosen by the user from four candidates compared on real interfaces (the prototype is on the
/// `prototype/comment-tag-styles` branch); `draft-source-editor-comment-annotations` records why.
final class SourceEditorCommentTagAppearance: NSObject, SourceEditorBridgingCommentTagAppearance {
    let valueColor: NSColor
    let typeColor: NSColor
    let nameColor: NSColor
    let disclosureColor: NSColor

    /// Past half a tag's height, so every tag is a capsule.
    let cornerRadius: CGFloat = 100

    let strokeWidth: CGFloat = 1

    /// Wider than a rounded rectangle needs, so the text keeps clear of the round ends.
    let horizontalPadding: CGFloat = 6

    private let fillColors: [SourceEditorBridgingCommentTagStyle: NSColor]
    private let strokeColors: [SourceEditorBridgingCommentTagStyle: NSColor]
    private let labelColors: [SourceEditorBridgingCommentTagStyle: NSColor]

    init(commentColor: NSColor, typeColor: NSColor, textColor: NSColor, isDark: Bool) {
        var fillColors: [SourceEditorBridgingCommentTagStyle: NSColor] = [:]
        var strokeColors: [SourceEditorBridgingCommentTagStyle: NSColor] = [:]
        var labelColors: [SourceEditorBridgingCommentTagStyle: NSColor] = [:]
        // Dark backgrounds need a stronger wash and line to show the same contrast.
        for style in SourceEditorBridgingCommentTagStyle.allCases {
            let hue = Self.hue(of: style, isDark: isDark) ?? commentColor
            fillColors[style] = hue.withAlphaComponent(isDark ? 0.11 : 0.075)
            strokeColors[style] = hue.withAlphaComponent(isDark ? 0.36 : 0.30)
            labelColors[style] = Self.labelShade(of: style, isDark: isDark) ?? commentColor
        }
        self.fillColors = fillColors
        self.strokeColors = strokeColors
        self.labelColors = labelColors
        // The theme's number colour is meant to stand out in code; inside a tag it shouted.
        self.valueColor = textColor.withAlphaComponent(isDark ? 0.82 : 0.78)
        self.typeColor = typeColor
        self.nameColor = textColor
        self.disclosureColor = commentColor
        super.init()
    }

    func fillColor(for style: SourceEditorBridgingCommentTagStyle) -> NSColor {
        fillColors[style] ?? .clear
    }

    func strokeColor(for style: SourceEditorBridgingCommentTagStyle) -> NSColor? {
        strokeColors[style]
    }

    func labelColor(for style: SourceEditorBridgingCommentTagStyle) -> NSColor {
        labelColors[style] ?? disclosureColor
    }

    // MARK: - Palette

    /// Each category's hue, a step off full saturation so a page of tags stays quiet; nil for
    /// notes, which take the comment colour.
    private static func hue(of style: SourceEditorBridgingCommentTagStyle, isDark: Bool) -> NSColor? {
        switch style {
        case .address: color(isDark ? (120, 165, 255) : (64, 120, 220))
        case .offset: color(isDark ? (100, 205, 150) : (46, 150, 100))
        case .layout: color(isDark ? (180, 150, 255) : (135, 95, 210))
        case .declaration: color(isDark ? (230, 185, 100) : (190, 135, 40))
        case .warning: color(isDark ? (255, 145, 100) : (225, 105, 55))
        case .note: nil
        }
    }

    /// The label's shade of each hue: deeper on a light background, lighter on a dark one.
    private static func labelShade(of style: SourceEditorBridgingCommentTagStyle, isDark: Bool) -> NSColor? {
        switch style {
        case .address: color(isDark ? (0x9D, 0xBE, 0xFF) : (0x2F, 0x5F, 0xB3))
        case .offset: color(isDark ? (0x8E, 0xDB, 0xB0) : (0x23, 0x7A, 0x50))
        case .layout: color(isDark ? (0xC9, 0xB2, 0xFF) : (0x6A, 0x45, 0xB0))
        case .declaration: color(isDark ? (0xE8, 0xC5, 0x8A) : (0x8C, 0x61, 0x18))
        case .warning: color(isDark ? (0xFF, 0xAD, 0x8C) : (0xB1, 0x4A, 0x1F))
        case .note: nil
        }
    }

    private static func color(_ components: (red: Int, green: Int, blue: Int)) -> NSColor {
        NSColor(srgbRed: CGFloat(components.red) / 255, green: CGFloat(components.green) / 255, blue: CGFloat(components.blue) / 255, alpha: 1)
    }
}
