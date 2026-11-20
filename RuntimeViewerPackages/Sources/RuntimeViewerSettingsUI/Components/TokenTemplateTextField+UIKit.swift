#if os(iOS) || os(visionOS)

import SwiftUI
import UIKit

// The UIKit template editor, the counterpart of the AppKit one in
// TransformerSettingsView.swift: `${name}` placeholders show as accent-tinted
// tokens, the bound text keeps the placeholders, and the field grows with its
// content.

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
    var didChangeHeightHandler: ((CGFloat) -> Void)?

    private var isTokenizing = false
    private var lastReportedWidth: CGFloat = 0

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

    /// The height the text needs at the current width.
    var contentHeight: CGFloat {
        let width = bounds.width > 0 ? bounds.width : 320
        return sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The first layout, and every width change, wraps the text anew.
        if bounds.width != lastReportedWidth {
            lastReportedWidth = bounds.width
            didChangeHeightHandler?(contentHeight)
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        tokenize()
        didChangeTextHandler?(templateString)
        didChangeHeightHandler?(contentHeight)
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
/// `${name}` placeholders, `height` follows the text.
struct TokenTemplateTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = TokenTemplateTextView()
        textView.didChangeTextHandler = { [weak coordinator = context.coordinator] newTemplate in
            guard let coordinator, !coordinator.isUpdatingFromSwiftUI else { return }
            coordinator.parent.text = newTemplate
        }
        textView.didChangeHeightHandler = { [weak coordinator = context.coordinator] newHeight in
            guard let coordinator, !coordinator.isUpdatingFromSwiftUI else { return }
            // Out of the view update that laid the text view out.
            DispatchQueue.main.async {
                coordinator.parent.height = newHeight
            }
        }
        context.coordinator.textView = textView
        textView.setTemplate(text)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        guard let textView = context.coordinator.textView, textView.templateString != text else { return }
        context.coordinator.isUpdatingFromSwiftUI = true
        textView.setTemplate(text)
        context.coordinator.isUpdatingFromSwiftUI = false
        DispatchQueue.main.async {
            self.height = textView.contentHeight
        }
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
