#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import os
import Semantic
import RuntimeViewerCore
import RuntimeViewerAppCore

/// The interval of a themed build, under the name the content pipeline has always used, so a trace
/// from before and after the theming moved into RuntimeViewerAppUI compares the same work.
private let contentTextSignposter = OSSignposter(
    subsystem: "com.RuntimeViewer.RuntimeViewerApplication",
    category: "Content.TextPipeline"
)

extension ContentInterface {
    /// The text in `theme`'s fonts and colours. On macOS each link of `links` carries its target as
    /// `.link`, which the `NSTextView` pane follows on a click; iOS shows no links, as it never did.
    ///
    /// Safe off the main thread: `ResolvedTheme`'s colour and font lookups are tables computed when it
    /// is made, and the result is an immutable copy.
    public func attributedString(themedWith theme: some ThemeProfile) -> NSAttributedString {
        let buildInterval = contentTextSignposter.beginInterval("content.attributedStringBuild", id: contentTextSignposter.makeSignpostID())
        defer { contentTextSignposter.endInterval("content.attributedStringBuild", buildInterval) }
        let attributedString = semanticString.mutableAttributedString(themedWith: theme)
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        attributedString.beginEditing()
        for link in links {
            attributedString.addAttribute(.link, value: link.target, range: link.range)
        }
        attributedString.endEditing()
        #endif
        // Immutable exit: the renderer builds this string on a background scheduler and hands it to
        // the main thread, so the mutable builder must not escape.
        return attributedString.copy() as! NSAttributedString
    }
}

extension FrozenSemanticString {
    /// The text with each span in the font and colour `theme` gives its semantic type.
    fileprivate func mutableAttributedString(themedWith theme: some ThemeProfile) -> NSMutableAttributedString {
        var attributesByType: [SemanticType: [NSAttributedString.Key: Any]] = [:]

        func attributes(for type: SemanticType) -> [NSAttributedString.Key: Any] {
            if let cachedAttributes = attributesByType[type] {
                return cachedAttributes
            }
            let typeAttributes: [NSAttributedString.Key: Any] = [
                .font: theme.font(for: type),
                .foregroundColor: theme.color(for: type),
            ]
            attributesByType[type] = typeAttributes
            return typeAttributes
        }

        // The frozen form stores the complete text once — no per-token concatenation pass is needed.
        let attributedString = NSMutableAttributedString(string: string)
        attributedString.beginEditing()
        var utf16Location = 0
        enumerateSpans { spanText, type, _ in
            let range = NSRange(location: utf16Location, length: spanText.utf16.count)
            utf16Location += range.length
            attributedString.setAttributes(attributes(for: type), range: range)
        }
        attributedString.endEditing()
        return attributedString
    }
}
