import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString {
    /// A row's title or subtitle: `string` in the system font of `fontSize`, left-aligned and truncated
    /// at the tail, in `color` when one is given and in the label's own colour otherwise.
    ///
    /// The one shape the rows used to build with UIFoundation's attributed string builder
    /// (`AText(…).foregroundColor(…).font(…).alignment(.left).lineBreakeMode(.byTruncatingTail)`), attribute
    /// for attribute: the builder merges the alignment and the line break mode into one paragraph style.
    package convenience init(rowText string: String, fontSize: CGFloat, color: NSUIColor? = nil) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSUIFont.systemFont(ofSize: fontSize),
            .paragraphStyle: paragraphStyle,
        ]
        if let color {
            attributes[.foregroundColor] = color
        }
        self.init(string: string, attributes: attributes)
    }
}
