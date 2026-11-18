#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import AppKitPlus
import RuntimeViewerAppCore

extension FindRecentQueries {
    /// `title(for:)` with the patterns drawn between the quotes as the query field draws them: the
    /// title of a recent query's item in the query field's menu (`FindQueryFieldMenuAdapter`).
    @MainActor
    package static func attributedTitle(for query: FindQuery, font: NSFont?) -> NSAttributedString {
        var textAttributes: [NSAttributedString.Key: Any] = [:]
        if let font {
            textAttributes[.font] = font
        }
        let attributedTitle = NSMutableAttributedString(string: titlePrefix(for: query), attributes: textAttributes)
        attributedTitle.append(query.term.findPatternComponents.attributedString(font: font, textColor: nil))
        attributedTitle.append(NSAttributedString(string: titleSuffix(for: query), attributes: textAttributes))
        return attributedTitle
    }
}

#endif
