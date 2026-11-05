import AppKit
import RuntimeViewerSourceEditorBridge

/// How the SourceEditor pane draws comment tags: a capsule per fact in one faint fill of the
/// comment colour, with no outline, and text kept below the code around it. The label carries a
/// trace of a hue per kind of fact, keys take the comment colour, and values, types and names
/// are their own colours at a reduced opacity. Worked out from the theme each time it is
/// applied; notes take the comment colour.
///
/// The first look gave every capsule its kind's hue and a hairline of the same hue, the label
/// that hue at full strength and the value 82 % of the text colour, which drew the comments
/// brighter than the declarations they describe. The user chose this one from five quieter
/// candidates; the proposal `source-editor-comment-annotations` records why.
final class SourceEditorCommentTagAppearance: NSObject, SourceEditorBridgingCommentTagAppearance {
    let keyColor: NSColor
    let valueColor: NSColor
    let typeColor: NSColor
    let nameColor: NSColor
    let disclosureColor: NSColor

    /// Past half a tag's height, so every tag is a capsule.
    let cornerRadius: CGFloat = 100

    /// No outline: a ring around each of the five capsules on a type layout's line was a large
    /// part of what made the tags loud.
    let strokeWidth: CGFloat = 0

    /// Wider than a rounded rectangle needs, so the text keeps clear of the round ends.
    let horizontalPadding: CGFloat = 6

    /// Two points above and two below every line that holds tags. Without it a tag filled its
    /// line all but a point each way, so the tags of a stored property's two comment lines read
    /// as one block and pressed against the code above and below.
    let tagLineSpacing: CGFloat = 4

    let commentFont: NSFont

    /// Behind every tag, whatever it says: the kind of fact shows in the label alone.
    private let neutralFillColor: NSColor
    private let labelColors: [SourceEditorBridgingCommentTagStyle: NSColor]

    init(commentColor: NSColor, commentFont: NSFont, typeColor: NSColor, textColor: NSColor, isDark: Bool) {
        self.commentFont = commentFont
        // Dark backgrounds need a stronger wash to show the same contrast.
        self.neutralFillColor = commentColor.withAlphaComponent(isDark ? 0.13 : 0.10)
        var labelColors: [SourceEditorBridgingCommentTagStyle: NSColor] = [:]
        for style in SourceEditorBridgingCommentTagStyle.allCases {
            labelColors[style] = Self.labelShade(of: style, isDark: isDark).map { Self.halfway(from: $0, to: commentColor) } ?? commentColor
        }
        self.labelColors = labelColors
        self.keyColor = commentColor
        // Values, types and names stay legible but under the code: the theme's number colour,
        // or the text colour at full strength, made a tag outshine the declaration below it.
        self.valueColor = textColor.withAlphaComponent(isDark ? 0.60 : 0.62)
        self.typeColor = typeColor.withAlphaComponent(isDark ? 0.62 : 0.70)
        self.nameColor = textColor.withAlphaComponent(isDark ? 0.60 : 0.62)
        self.disclosureColor = commentColor
        super.init()
    }

    func fillColor(for style: SourceEditorBridgingCommentTagStyle) -> NSColor {
        neutralFillColor
    }

    func strokeColor(for style: SourceEditorBridgingCommentTagStyle) -> NSColor? {
        nil
    }

    func labelColor(for style: SourceEditorBridgingCommentTagStyle) -> NSColor {
        labelColors[style] ?? disclosureColor
    }

    // MARK: - Palette

    /// Each kind's label shade at full strength: deeper on a light background, lighter on a dark
    /// one. Nil for notes, which take the comment colour. A label is drawn halfway from its shade
    /// to the comment colour.
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

    /// The colour halfway between `shade` and `commentColor` in sRGB, alpha included, so a label
    /// keeps a trace of its hue and sits near the comment colour of whatever theme is in use. A
    /// colour with no sRGB form, such as a pattern, leaves the shade as it is.
    private static func halfway(from shade: NSColor, to commentColor: NSColor) -> NSColor {
        guard let shadeInSRGB = shade.usingColorSpace(.sRGB),
              let commentColorInSRGB = commentColor.usingColorSpace(.sRGB)
        else { return shade }
        return NSColor(
            srgbRed: (shadeInSRGB.redComponent + commentColorInSRGB.redComponent) / 2,
            green: (shadeInSRGB.greenComponent + commentColorInSRGB.greenComponent) / 2,
            blue: (shadeInSRGB.blueComponent + commentColorInSRGB.blueComponent) / 2,
            alpha: (shadeInSRGB.alphaComponent + commentColorInSRGB.alphaComponent) / 2
        )
    }

    private static func color(_ components: (red: Int, green: Int, blue: Int)) -> NSColor {
        NSColor(srgbRed: CGFloat(components.red) / 255, green: CGFloat(components.green) / 255, blue: CGFloat(components.blue) / 255, alpha: 1)
    }
}
