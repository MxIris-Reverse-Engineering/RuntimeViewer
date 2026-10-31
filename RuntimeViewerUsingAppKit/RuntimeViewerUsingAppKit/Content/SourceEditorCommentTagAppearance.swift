import AppKit

/// How the SourceEditor pane draws comment tags: a faint fill per kind of fact, the label in a
/// shade of the same hue, and the shape around them. Worked out from the theme each time it is
/// applied.
final class SourceEditorCommentTagAppearance: NSObject, SourceEditorBridgingCommentTagAppearance {
    /// The candidates being compared. Prototype only: the one chosen stays, the others go.
    enum Variant: CaseIterable {
        /// Before the comparison: one wash of the comment colour, radius 4.
        case current
        /// A pale fill per category, radius 5.
        case softTints
        /// Capsules, a paler fill and a hairline of the same hue.
        case capsules
        /// One neutral fill, the colour only on the label.
        case tintedLabels

        var title: String {
            switch self {
            case .current: "现状（对照）"
            case .softTints: "A · 淡彩圆角"
            case .capsules: "B · 胶囊细边"
            case .tintedLabels: "C · 只给标签名上色"
            }
        }
    }

    let valueColor: NSColor
    let typeColor: NSColor
    let nameColor: NSColor
    let disclosureColor: NSColor
    let cornerRadius: CGFloat
    let strokeWidth: CGFloat
    let horizontalPadding: CGFloat

    private let fillColors: [SourceEditorBridgingCommentTagStyle: NSColor]
    private let strokeColors: [SourceEditorBridgingCommentTagStyle: NSColor]
    private let labelColors: [SourceEditorBridgingCommentTagStyle: NSColor]

    init(variant: Variant, commentColor: NSColor, numberColor: NSColor, typeColor: NSColor, textColor: NSColor, isDark: Bool) {
        var fillColors: [SourceEditorBridgingCommentTagStyle: NSColor] = [:]
        var strokeColors: [SourceEditorBridgingCommentTagStyle: NSColor] = [:]
        var labelColors: [SourceEditorBridgingCommentTagStyle: NSColor] = [:]
        let quietTextColor = textColor.withAlphaComponent(isDark ? 0.82 : 0.78)

        switch variant {
        case .current:
            for style in SourceEditorBridgingCommentTagStyle.allCases {
                fillColors[style] = switch style {
                case .warning: NSColor.systemOrange.withAlphaComponent(isDark ? 0.28 : 0.18)
                case .note: commentColor.withAlphaComponent(isDark ? 0.09 : 0.06)
                default: commentColor.withAlphaComponent(isDark ? 0.18 : 0.11)
                }
                labelColors[style] = commentColor
            }
            valueColor = numberColor
            cornerRadius = 4
            strokeWidth = 0
            horizontalPadding = 4

        case .softTints:
            for style in SourceEditorBridgingCommentTagStyle.allCases {
                let hue = Self.hue(of: style, isDark: isDark) ?? commentColor
                fillColors[style] = hue.withAlphaComponent(isDark ? 0.16 : 0.11)
                labelColors[style] = Self.labelShade(of: style, isDark: isDark) ?? commentColor
            }
            valueColor = quietTextColor
            cornerRadius = 5
            strokeWidth = 0
            horizontalPadding = 4

        case .capsules:
            for style in SourceEditorBridgingCommentTagStyle.allCases {
                let hue = Self.hue(of: style, isDark: isDark) ?? commentColor
                fillColors[style] = hue.withAlphaComponent(isDark ? 0.11 : 0.075)
                strokeColors[style] = hue.withAlphaComponent(isDark ? 0.36 : 0.30)
                labelColors[style] = Self.labelShade(of: style, isDark: isDark) ?? commentColor
            }
            valueColor = quietTextColor
            // Anything past half the tag's height is a capsule.
            cornerRadius = 100
            strokeWidth = 1
            horizontalPadding = 6

        case .tintedLabels:
            for style in SourceEditorBridgingCommentTagStyle.allCases {
                fillColors[style] = if style == .warning, let warningHue = Self.hue(of: .warning, isDark: isDark) {
                    warningHue.withAlphaComponent(isDark ? 0.16 : 0.11)
                } else {
                    commentColor.withAlphaComponent(isDark ? 0.13 : 0.085)
                }
                labelColors[style] = Self.labelShade(of: style, isDark: isDark) ?? commentColor
            }
            valueColor = quietTextColor
            cornerRadius = 5
            strokeWidth = 0
            horizontalPadding = 4
        }

        self.fillColors = fillColors
        self.strokeColors = strokeColors
        self.labelColors = labelColors
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
