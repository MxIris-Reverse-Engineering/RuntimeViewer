import AppKit
import SwiftUI
import SettingsKit
import Dependencies
import RuntimeViewerSettings
import RuntimeViewerCore

struct TransformerSettingsView: SettingsContent {
    @AppSettings(\.transformer)
    var config

    var body: some SettingsContent {
        SettingsGroup("Transformer", .navigation) {
            SettingsForm {
                // MARK: - C Type Module

                Section {
                    Toggle("Transform C Types", isOn: $config.objc.cType.isEnabled)
                } footer: {
                    Text("Transform C primitive types to custom types in ObjC interfaces.")
                }

                if config.objc.cType.isEnabled {
                    Section {
                        CTypeEditor(module: $config.objc.cType)
                    } header: {
                        HStack {
                            Text("Type Replacements")
                            Spacer()
                            CTypePresets(module: $config.objc.cType)
                        }
                    }
                }

                // MARK: - Swift Field Offset Module

                Section {
                    Toggle("Transform Swift Field Offset Comment", isOn: $config.swift.swiftFieldOffset.isEnabled)
                } footer: {
                    Text("Transform Swift field offset comment format in Swift interfaces.")
                }

                if config.swift.swiftFieldOffset.isEnabled {
                    Section {
                        SwiftFieldOffsetEditor(module: $config.swift.swiftFieldOffset)
                    } header: {
                        Text("Output Format")
                    }
                }

                // MARK: - Swift Type Layout Module

                Section {
                    Toggle("Transform Swift Type Layout Comment", isOn: $config.swift.swiftTypeLayout.isEnabled)
                } footer: {
                    Text("Transform Swift type layout comment format in Swift interfaces.")
                }

                if config.swift.swiftTypeLayout.isEnabled {
                    Section {
                        SwiftTypeLayoutEditor(module: $config.swift.swiftTypeLayout)
                    } header: {
                        Text("Output Format")
                    }
                }

                // MARK: - Swift Enum Layout Module

                Section {
                    Toggle("Transform Swift Enum Layout Comment", isOn: $config.swift.swiftEnumLayout.isEnabled)
                } footer: {
                    Text("Transform Swift enum layout comment format in Swift interfaces.")
                }

                if config.swift.swiftEnumLayout.isEnabled {
                    Section {
                        SwiftEnumLayoutEditor(module: $config.swift.swiftEnumLayout)
                    } header: {
                        Text("Output Format")
                    }
                }
            }
        } icon: {
            SettingsIcon(symbol: "arrow.triangle.2.circlepath", color: .clear)
        }
    }
}

// MARK: - C Type Editor

private struct CTypeEditor: View {
    @Binding var module: Transformer.CType

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(Transformer.CType.Pattern.allCases, id: \.self) { pattern in
                GridRow {
                    HStack(spacing: 6) {
                        Text(pattern.displayName)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .fixedSize()
                    .gridColumnAlignment(.trailing)

                    TextField(
                        "Replacement",
                        text: Binding(
                            get: {
                                module.replacements[pattern] ?? ""
                            },
                            set: { newValue in
                                if newValue.isEmpty {
                                    module.replacements.removeValue(forKey: pattern)
                                } else {
                                    module.replacements[pattern] = newValue
                                }
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                }
            }
        }
    }
}

// MARK: - C Type Presets

private struct CTypePresets: View {
    @Binding var module: Transformer.CType

    var body: some View {
        HStack(spacing: 6) {
            Button("stdint") {
                module.replacements = Transformer.CType.Presets.stdint
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("uint32_t, int64_t, etc.")

            Button("Foundation") {
                module.replacements = Transformer.CType.Presets.foundation
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("CGFloat, NSInteger, etc.")
            
            Button("Mixed") {
                module.replacements = Transformer.CType.Presets.mixed
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Clear") {
                module.replacements.removeAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - Token Text Attachment

private final class TokenTextAttachment: NSTextAttachment {}

private final class TokenTextAttachmentCell: NSTextAttachmentCell, @unchecked Sendable {
    let tokenName: String
    let tokenPlaceholder: String

    init(tokenName: String) {
        self.tokenName = tokenName
        self.tokenPlaceholder = "${\(tokenName)}"
        super.init(textCell: tokenPlaceholder)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static let effectiveFont: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)

    private static let innerPadding: CGFloat = 5

    override func cellSize() -> NSSize {
        let textSize = (tokenName as NSString).size(withAttributes: [.font: Self.effectiveFont])
        return NSSize(width: textSize.width + Self.innerPadding * 2, height: textSize.height + 2)
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: Self.effectiveFont.descender)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let context = NSGraphicsContext.current else { return }
        let accentColor = NSColor.controlAccentColor

        context.saveGraphicsState()
        accentColor.withAlphaComponent(0.15).setFill()
        let path = NSBezierPath(roundedRect: cellFrame, xRadius: 4, yRadius: 4)
        path.fill()
        context.restoreGraphicsState()

        let attributed = NSAttributedString(string: tokenName, attributes: [
            .font: Self.effectiveFont,
            .foregroundColor: accentColor,
        ])
        let textSize = attributed.size()
        var drawPoint = cellFrame.origin
        drawPoint.x += (cellFrame.width - textSize.width) / 2
        drawPoint.y += (cellFrame.height - textSize.height) / 2
        attributed.draw(at: drawPoint)
    }
}

// MARK: - Token Template Text View

private final class TokenTemplateTextView: NSTextView {
    var didChangeTextHandler: ((String) -> Void)?
    var didChangeHeightHandler: ((CGFloat) -> Void)?

    override var string: String {
        didSet { tokenize() }
    }

    /// Returns the raw template string with ${...} placeholders restored.
    var templateString: String {
        attributedString().untokenized.string
    }

    func commonInit() {
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textColor = .textColor
        isEditable = true
        isSelectable = true
        isRichText = true
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 4
        drawsBackground = false
        textContainerInset = NSSize(width: 0, height: 2)
        typingAttributes = [
            .font: font as Any,
            .foregroundColor: NSColor.textColor,
        ]
    }

    /// Computes the content height based on the text layout.
    var contentHeight: CGFloat {
        guard let layoutManager, let textContainer else { return 24 }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return usedRect.height + textContainerInset.height * 2
    }

    override func didChangeText() {
        super.didChangeText()
        tokenize()
        didChangeTextHandler?(templateString)
        didChangeHeightHandler?(contentHeight)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let selected = attributedString().attributedSubstring(from: selectedRange())
        pboard.clearContents()
        pboard.writeObjects([selected.untokenized])
        return true
    }

    private func tokenize() {
        guard let textStorage else { return }
        let pattern = #"\$\{([^}]+)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let string = textStorage.string
        let range = NSRange(string.startIndex..., in: string)
        let matches = regex.matches(in: string, range: range)

        let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]

        textStorage.beginEditing()
        textStorage.setAttributes(defaultAttributes, range: range)
        for match in matches.reversed() {
            let nsString = string as NSString
            let fullMatch = nsString.substring(with: match.range)
            let tokenName = fullMatch
                .replacingOccurrences(of: "${", with: "")
                .replacingOccurrences(of: "}", with: "")
            let attachment = TokenTextAttachment()
            let cell = TokenTextAttachmentCell(tokenName: tokenName)
            attachment.attachmentCell = cell
            textStorage.replaceCharacters(in: match.range, with: NSAttributedString(attachment: attachment))
        }
        textStorage.endEditing()
    }
}

extension NSAttributedString {
    /// Converts attachment-based tokens back to ${...} placeholder strings.
    fileprivate var untokenized: NSAttributedString {
        let result = mutableCopy() as! NSMutableAttributedString
        let fullRange = NSRange(string.startIndex..., in: string)
        enumerateAttribute(.attachment, in: fullRange, options: .reverse) { value, range, _ in
            guard let attachment = value as? TokenTextAttachment,
                  let cell = attachment.attachmentCell as? TokenTextAttachmentCell else { return }
            result.replaceCharacters(in: range, with: NSAttributedString(string: cell.tokenPlaceholder))
        }
        return result
    }
}

// MARK: - Token Template Text Field (SwiftUI wrapper)

private struct TokenTemplateTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = TokenTemplateTextView.scrollableTextView()
        let textView = scrollView.documentView as! TokenTemplateTextView
        textView.commonInit()
        textView.didChangeTextHandler = { [weak coordinator = context.coordinator] newTemplate in
            guard let coordinator, !coordinator.isUpdatingFromSwiftUI else { return }
            coordinator.parent.text = newTemplate
        }
        textView.didChangeHeightHandler = { [weak coordinator = context.coordinator] newHeight in
            guard let coordinator, !coordinator.isUpdatingFromSwiftUI else { return }
            coordinator.parent.height = newHeight
        }
        context.coordinator.textView = textView

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 6
        scrollView.layer?.masksToBounds = true
        scrollView.borderType = .noBorder

        textView.string = text

        DispatchQueue.main.async {
            self.height = textView.contentHeight
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.templateString != text {
            context.coordinator.isUpdatingFromSwiftUI = true
            textView.string = text
            context.coordinator.isUpdatingFromSwiftUI = false
            DispatchQueue.main.async {
                self.height = textView.contentHeight
            }
        }
    }

    final class Coordinator: NSObject {
        var parent: TokenTemplateTextField
        weak var textView: TokenTemplateTextView?
        var isUpdatingFromSwiftUI = false

        init(parent: TokenTemplateTextField) {
            self.parent = parent
        }
    }
}

// MARK: - Copyable Token Chip

private struct CopyableTokenChip<Token: RawRepresentable & Hashable>: View where Token.RawValue == String {
    let token: Token
    let placeholder: String

    @State private var copied = false

    var body: some View {
        Button {
            copyToClipboard(placeholder)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Text(token.rawValue)
                    .font(.system(.caption, design: .monospaced))
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied!" : "Click to copy \(placeholder)")
        .animation(.easeInOut(duration: 0.2), value: copied)
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Swift Field Offset Editor

private struct SwiftFieldOffsetEditor: View {
    @Binding var module: Transformer.SwiftFieldOffset
    @State private var textFieldHeight: CGFloat = 24

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
            // Token-styled template editor
            GridRow {
                Text("Template")
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)

                TokenTemplateTextField(text: $module.template, height: $textFieldHeight)
                    .frame(height: max(24, textFieldHeight))
            }

            // Radix picker
            GridRow {
                Text("Radix")
                    .foregroundStyle(.secondary)

                Picker("", selection: $module.useHexadecimal) {
                    Text("Decimal").tag(false)
                    Text("Hexadecimal").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            // Copyable token chips
            GridRow {
                Text("Tokens")
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(Transformer.SwiftFieldOffset.Token.allCases, id: \.self) { token in
                        CopyableTokenChip(token: token, placeholder: token.placeholder)
                    }
                }
            }

            // Preset buttons
            GridRow {
                Text("Presets")
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftFieldOffset.Templates.all, id: \.name) { preset in
                        Button(preset.name) {
                            module.template = preset.template
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: - Swift Type Layout Editor

private struct SwiftTypeLayoutEditor: View {
    @Binding var module: Transformer.SwiftTypeLayout
    @State private var textFieldHeight: CGFloat = 24

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
            // Token-styled template editor
            GridRow {
                Text("Template")
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)

                TokenTemplateTextField(text: $module.template, height: $textFieldHeight)
                    .frame(height: max(24, textFieldHeight))
            }

            // Radix picker
            GridRow {
                Text("Radix")
                    .foregroundStyle(.secondary)

                Picker("", selection: $module.useHexadecimal) {
                    Text("Decimal").tag(false)
                    Text("Hexadecimal").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            // Copyable token chips
            GridRow {
                Text("Tokens")
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftTypeLayout.Token.allCases, id: \.self) { token in
                        CopyableTokenChip(token: token, placeholder: token.placeholder)
                    }
                }
            }

            // Preset buttons
            GridRow {
                Text("Presets")
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftTypeLayout.Templates.all, id: \.name) { preset in
                        Button(preset.name) {
                            module.template = preset.template
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: - Swift Enum Layout Editor

private struct SwiftEnumLayoutEditor: View {
    @Binding var module: Transformer.SwiftEnumLayout
    @State private var strategyFieldHeight: CGFloat = 24
    @State private var caseFieldHeight: CGFloat = 24

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
            // Strategy header template editor
            GridRow {
                Text("Strategy\nTemplate")
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)

                TokenTemplateTextField(text: $module.template, height: $strategyFieldHeight)
                    .frame(height: max(24, strategyFieldHeight))
            }

            // Strategy token chips
            GridRow {
                Text("Tokens")
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftEnumLayout.Token.allCases, id: \.self) { token in
                        CopyableTokenChip(token: token, placeholder: token.placeholder)
                    }
                }
            }

            // Strategy preset buttons
            GridRow {
                Text("Presets")
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftEnumLayout.Templates.all, id: \.name) { preset in
                        Button(preset.name) {
                            module.template = preset.template
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Divider()
                .gridCellColumns(2)

            // Per-case template editor
            GridRow {
                Text("Case\nTemplate")
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)

                TokenTemplateTextField(text: $module.caseTemplate, height: $caseFieldHeight)
                    .frame(height: max(24, caseFieldHeight))
            }

            // Case token chips
            GridRow {
                Text("Tokens")
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftEnumLayout.CaseToken.allCases, id: \.self) { token in
                        CopyableTokenChip(token: token, placeholder: token.placeholder)
                    }
                }
            }

            // Case preset buttons
            GridRow {
                Text("Presets")
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftEnumLayout.CaseTemplates.all, id: \.name) { preset in
                        Button(preset.name) {
                            module.caseTemplate = preset.template
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Divider()
                .gridCellColumns(2)

            // Radix picker (shared)
            GridRow {
                Text("Radix")
                    .foregroundStyle(.secondary)

                Picker("", selection: $module.useHexadecimal) {
                    Text("Decimal").tag(false)
                    Text("Hexadecimal").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX - spacing)
        }

        return (CGSize(width: maxX, height: currentY + lineHeight), positions)
    }
}
