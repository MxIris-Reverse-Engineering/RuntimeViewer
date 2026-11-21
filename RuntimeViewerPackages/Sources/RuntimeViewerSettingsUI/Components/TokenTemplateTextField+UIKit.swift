#if os(iOS) || os(visionOS)

import SwiftUI
import UIKit

// The UIKit template editor, the counterpart of the AppKit one in
// TransformerSettingsView.swift: `${name}` placeholders show as accent-tinted
// tokens, the bound text keeps the placeholders, and the field takes the width
// it is offered and the height its wrapped text needs.

// MARK: - Token Text Attachment

/// A token shown in place of `${tokenName}`, drawn as a rounded chip.
private final class TokenTextAttachment: NSTextAttachment {
    let tokenName: String

    var placeholder: String {
        TokenTemplatePlaceholder.placeholder(forName: tokenName)
    }

    private static let chipFont = UIFont.monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .medium)
    private static let innerPadding: CGFloat = 5

    init(tokenName: String, tintColor: UIColor) {
        self.tokenName = tokenName
        super.init(data: nil, ofType: nil)
        let chip = Self.chipImage(named: tokenName, tintColor: tintColor)
        image = chip
        bounds = CGRect(x: 0, y: Self.chipFont.descender, width: chip.size.width, height: chip.size.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The same chip the AppKit editor draws: the name in the accent colour
    /// on the accent colour at 15 %, corners of 4 points.
    private static func chipImage(named tokenName: String, tintColor: UIColor) -> UIImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: chipFont,
            .foregroundColor: tintColor,
        ]
        let textSize = (tokenName as NSString).size(withAttributes: attributes)
        let chipSize = CGSize(width: ceil(textSize.width) + innerPadding * 2, height: ceil(textSize.height) + 2)
        return UIGraphicsImageRenderer(size: chipSize).image { _ in
            tintColor.withAlphaComponent(0.15).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: chipSize), cornerRadius: 4).fill()
            let textOrigin = CGPoint(x: (chipSize.width - textSize.width) / 2, y: (chipSize.height - textSize.height) / 2)
            (tokenName as NSString).draw(at: textOrigin, withAttributes: attributes)
        }
    }
}

// MARK: - Token Template Text View

private final class TokenTemplateTextView: UITextView, UITextViewDelegate {
    var didChangeTextHandler: ((String) -> Void)?

    private var isTokenizing = false

    private static let defaultAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular),
        .foregroundColor: UIColor.label,
    ]

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        isScrollEnabled = false
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        spellCheckingType = .no
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 6
        layer.masksToBounds = true
        textContainer.lineFragmentPadding = 4
        textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        typingAttributes = Self.defaultAttributes
        // With scrolling off, the intrinsic width is the whole template on one
        // line; the field wraps to the width it is given instead.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The template with every token turned back into its `${name}`.
    var templateString: String {
        Self.untokenized(attributedText).string
    }

    /// Shows `template`, its placeholders as tokens.
    func setTemplate(_ template: String) {
        attributedText = NSAttributedString(string: template, attributes: Self.defaultAttributes)
        tokenize()
    }

    func textViewDidChange(_ textView: UITextView) {
        tokenize()
        didChangeTextHandler?(templateString)
        // A new line of text asks SwiftUI for the height again.
        invalidateIntrinsicContentSize()
    }

    /// Copies the selection with its tokens as `${name}`, so pasting it
    /// anywhere else gives the template text.
    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else { return }
        let selected = attributedText.attributedSubstring(from: selectedRange)
        UIPasteboard.general.string = Self.untokenized(selected).string
    }

    /// Turns new `${name}` text into tokens, keeping the tokens already shown
    /// and the caret where the user left it.
    private func tokenize() {
        guard !isTokenizing else { return }
        isTokenizing = true
        defer { isTokenizing = false }

        let matches = TokenTemplatePlaceholder.matches(in: textStorage.string)
        let selection = selectedRange
        let fullRange = NSRange(location: 0, length: textStorage.length)

        textStorage.beginEditing()
        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            if value == nil {
                textStorage.setAttributes(Self.defaultAttributes, range: range)
            }
        }
        for match in matches.reversed() {
            let attachment = TokenTextAttachment(tokenName: match.name, tintColor: tintColor)
            textStorage.replaceCharacters(in: match.range, with: NSAttributedString(attachment: attachment))
        }
        textStorage.endEditing()

        if !matches.isEmpty {
            let caretLocation = TokenTemplatePlaceholder.caretLocation(selection.location, afterReplacing: matches)
            selectedRange = NSRange(location: max(0, min(caretLocation, textStorage.length)), length: 0)
        }
        typingAttributes = Self.defaultAttributes
    }

    private static func untokenized(_ attributedString: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributedString)
        let fullRange = NSRange(location: 0, length: attributedString.length)
        attributedString.enumerateAttribute(.attachment, in: fullRange, options: .reverse) { value, range, _ in
            guard let attachment = value as? TokenTextAttachment else { return }
            result.replaceCharacters(in: range, with: attachment.placeholder)
        }
        return result
    }
}

// MARK: - Token Template Text Field (SwiftUI wrapper)

/// The template editor the transformer page shows: `text` keeps the
/// `${name}` placeholders.
struct TokenTemplateTextField: UIViewRepresentable {
    @Binding var text: String

    /// The height of an empty field, as on macOS.
    private static let minimumHeight: CGFloat = 24

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = TokenTemplateTextView()
        textView.didChangeTextHandler = { [weak coordinator = context.coordinator] newTemplate in
            guard let coordinator, !coordinator.isUpdatingFromSwiftUI else { return }
            coordinator.parent.text = newTemplate
        }
        context.coordinator.textView = textView
        textView.setTemplate(text)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView, textView.templateString != text else { return }
        context.coordinator.isUpdatingFromSwiftUI = true
        textView.setTemplate(text)
        context.coordinator.isUpdatingFromSwiftUI = false
        textView.invalidateIntrinsicContentSize()
    }

    /// The width SwiftUI offers, and the height the text needs wrapped to it.
    /// Left to its intrinsic size, a text view that does not scroll lays the
    /// template out on one line and pushes the row wider than the screen.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fittingSize = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(Self.minimumHeight, ceil(fittingSize.height)))
    }

    final class Coordinator: NSObject {
        var parent: TokenTemplateTextField
        fileprivate weak var textView: TokenTemplateTextView?
        /// Set while SwiftUI's text goes into the view, so the change it
        /// causes is not written back.
        var isUpdatingFromSwiftUI = false

        init(parent: TokenTemplateTextField) {
            self.parent = parent
        }
    }
}

#endif
