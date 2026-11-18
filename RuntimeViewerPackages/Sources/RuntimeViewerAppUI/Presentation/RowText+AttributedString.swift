import Foundation
import RuntimeViewerAppCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// How a list draws `RowText`'s roles: the font, colour and paragraph style of each.
public struct RowTextStyle {
    fileprivate let attributes: (_ role: RowText.Role, _ fontSize: CGFloat?) -> [NSAttributedString.Key: Any]

    /// A navigator's, an inspector's or Open Quickly's row: the system font at the row's size (13 points
    /// when it names none), left-aligned and cut at its end. The name is in the label colour, a subtitle
    /// in the secondary one, what a filter did not match in the secondary or tertiary one, and what it
    /// matched in the label colour, semibold — as `NSAttributedString(rowText:fontSize:color:)` draws
    /// them.
    public static let list = RowTextStyle { role, fontSize in
        let pointSize = fontSize ?? 13
        let color: NSUIColor
        var font = NSUIFont.systemFont(ofSize: pointSize)
        switch role {
        case .primary, .hitLine:
            color = .labelColor
        case .secondary, .unresolved:
            color = .secondaryLabelColor
        case .tertiary:
            color = .tertiaryLabelColor
        case .emphasized:
            color = .labelColor
            font = NSUIFont.systemFont(ofSize: pointSize, weight: .semibold)
        }
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: rowParagraphStyle,
        ]
    }

    /// Left-aligned, cut at its end, as a row's title always was.
    private static let rowParagraphStyle: NSParagraphStyle = {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byTruncatingTail
        return paragraphStyle
    }()

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    /// The Find navigator's and the Inspector's References tab's rows at `metrics`' sizes: a name in the
    /// title font, a subtitle in the subtitle font, a hit's line in Xcode's hit-line colour with the hit in
    /// bold. The text's own size is not used: the metrics decide it.
    public static func findResult(_ metrics: FindResultCellStyle.Metrics) -> RowTextStyle {
        RowTextStyle { role, _ in
            switch role {
            case .primary:
                [.font: metrics.titleFont, .foregroundColor: FindResultCellStyle.titleColor, .paragraphStyle: FindResultCellStyle.titleParagraphStyle]
            case .secondary:
                [.font: metrics.subtitleFont, .foregroundColor: FindResultCellStyle.subtitleColor, .paragraphStyle: FindResultCellStyle.titleParagraphStyle]
            case .tertiary:
                [.font: metrics.subtitleFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: FindResultCellStyle.titleParagraphStyle]
            case .unresolved:
                [.font: metrics.titleFont, .foregroundColor: FindResultCellStyle.unresolvedTitleColor, .paragraphStyle: FindResultCellStyle.titleParagraphStyle]
            case .hitLine:
                [.font: FindResultCellStyle.hitLineFont, .foregroundColor: FindResultCellStyle.hitLineColor]
            case .emphasized:
                [.font: FindResultCellStyle.emphasisFont, .foregroundColor: FindResultCellStyle.emphasisColor]
            }
        }
    }
    #endif
}

extension RowText {
    /// The text in `style`'s fonts and colours, run by run.
    public func attributedString(in style: RowTextStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            result.append(NSAttributedString(string: run.string, attributes: style.attributes(run.role, fontSize)))
        }
        return result
    }
}
