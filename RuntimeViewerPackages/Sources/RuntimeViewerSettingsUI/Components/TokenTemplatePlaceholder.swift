import Foundation

/// The `${name}` placeholders in a transformer template, which the template
/// editor shows as tokens.
///
/// The UIKit editor finds and restores placeholders through this. The AppKit
/// editor keeps its own copy of the same rules (`TokenTemplateTextView` in
/// `TransformerSettingsView.swift`), written before this existed; the two
/// must agree, and `TokenTemplatePlaceholderTests` pins these rules.
enum TokenTemplatePlaceholder {
    struct Match: Equatable {
        /// The whole `${name}`, in UTF-16 units of the searched text.
        let range: NSRange
        /// The token name: what the placeholder holds without `${` and `}`.
        let name: String
    }

    /// `${name}` around a token name — what a token stands for.
    static func placeholder(forName name: String) -> String {
        "${\(name)}"
    }

    /// Every `${name}` in `text`, in order. An object replacement character
    /// (U+FFFC), which stands for a token already shown, is not a placeholder.
    static func matches(in text: String) -> [Match] {
        let nsText = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map { result in
            let fullMatch = nsText.substring(with: result.range)
            let name = fullMatch
                .replacingOccurrences(of: "${", with: "")
                .replacingOccurrences(of: "}", with: "")
            return Match(range: result.range, name: name)
        }
    }

    /// Where a caret at `location` lands once each of `matches` is replaced by
    /// a single token character: every match that ends at or before it moves
    /// it back by its length less one.
    static func caretLocation(_ location: Int, afterReplacing matches: [Match]) -> Int {
        let removedLength = matches
            .filter { $0.range.location + $0.range.length <= location }
            .reduce(0) { $0 + $1.range.length - 1 }
        return location - removedLength
    }

    // A literal pattern; it cannot fail to compile.
    private static let expression = try! NSRegularExpression(pattern: #"\$\{([^}]+)\}"#)
}
