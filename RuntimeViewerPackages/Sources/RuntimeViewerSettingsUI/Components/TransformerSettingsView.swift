#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import Dependencies
import RuntimeViewerSettings
import RuntimeViewerCore
import UIFoundationSettingsUI

struct TransformerSettingsView: View {
    @AppSettings(\.transformer)
    var config

    var body: some View {
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

            // MARK: - ObjC Ivar Offset Module

            Section {
                Toggle("Transform ObjC Ivar Offset Comment", isOn: $config.objc.ivarOffset.isEnabled)
            } footer: {
                Text("Transform ObjC ivar offset comment format in ObjC interfaces.")
            }

            if config.objc.ivarOffset.isEnabled {
                Section {
                    ObjCIvarOffsetEditor(module: $config.objc.ivarOffset)
                } header: {
                    Text("Output Format")
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

            // MARK: - Swift VTable Offset Module

            Section {
                Toggle("Transform Swift VTable Offset Comment", isOn: $config.swift.swiftVTableOffset.isEnabled)
            } footer: {
                Text("Transform Swift vtable offset comment format in Swift interfaces.")
            }

            if config.swift.swiftVTableOffset.isEnabled {
                Section {
                    SwiftVTableOffsetEditor(module: $config.swift.swiftVTableOffset)
                } header: {
                    Text("Output Format")
                }
            }

            // MARK: - Swift Member Address Module

            Section {
                Toggle("Transform Swift Member Address Comment", isOn: $config.swift.swiftMemberAddress.isEnabled)
            } footer: {
                Text("Transform Swift member address comment format in Swift interfaces.")
            }

            if config.swift.swiftMemberAddress.isEnabled {
                Section {
                    SwiftMemberAddressEditor(module: $config.swift.swiftMemberAddress)
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
        #if os(macOS)
        buttons
        #else
        // An iOS section header has no room for four buttons beside its title.
        Menu("Presets") {
            Button("stdint") {
                module.replacements = Transformer.CType.Presets.stdint
            }
            Button("Foundation") {
                module.replacements = Transformer.CType.Presets.foundation
            }
            Button("Mixed") {
                module.replacements = Transformer.CType.Presets.mixed
            }
            Divider()
            Button("Clear", role: .destructive) {
                module.replacements.removeAll()
            }
        }
        #endif
    }

    #if os(macOS)
    private var buttons: some View {
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
    #endif
}

// MARK: - ObjC Ivar Offset Editor

private struct ObjCIvarOffsetEditor: View {
    @Binding var module: Transformer.ObjCIvarOffset

    var body: some View {
        EditorGrid {
            EditorRow(label: "Template") {
                TemplateField(text: $module.template)
            }

            EditorRow(label: "Radix") {
                Picker("", selection: $module.useHexadecimal) {
                    Text("Decimal").tag(false)
                    Text("Hexadecimal").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            EditorRow(label: "Tokens") {
                FlowLayout(spacing: 8) {
                    ForEach(Transformer.ObjCIvarOffset.Token.allCases, id: \.self) { token in
                        CopyableTokenChip(token: token, placeholder: token.placeholder)
                    }
                }
            }

            EditorRow(label: "Presets") {
                FlowLayout(spacing: 6) {
                    ForEach(Transformer.ObjCIvarOffset.Templates.all, id: \.name) { preset in
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

#if os(macOS)
// The AppKit template editor. The UIKit one is in TokenTemplateTextField+UIKit.swift.

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

    private var isTokenizing = false

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

    private static let defaultAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        .foregroundColor: NSColor.textColor,
    ]

    /// Converts new ${...} text patterns into attachment characters.
    /// Existing attachments (U+FFFC) are NOT matched by the regex, so they are preserved.
    private func tokenize() {
        guard let textStorage, !isTokenizing else { return }
        isTokenizing = true
        defer { isTokenizing = false }

        let string = textStorage.string
        let fullRange = NSRange(location: 0, length: textStorage.length)

        let pattern = #"\$\{([^}]+)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = regex.matches(in: string, range: fullRange)

        let sel = selectedRange()

        textStorage.beginEditing()

        // Apply default attributes only to non-attachment ranges
        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            if value == nil {
                textStorage.setAttributes(Self.defaultAttributes, range: range)
            }
        }

        // Replace ${...} text with attachment characters (reverse order preserves ranges)
        var cursorAdjustment = 0
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

            // Adjust cursor position for replacements before cursor
            if match.range.location + match.range.length <= sel.location {
                cursorAdjustment -= (match.range.length - 1)
            }
        }

        textStorage.endEditing()

        // Restore cursor position accounting for text length changes
        if cursorAdjustment != 0 {
            let newPos = max(0, min(sel.location + cursorAdjustment, textStorage.length))
            setSelectedRange(NSRange(location: newPos, length: 0))
        }
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

#endif

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
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

// MARK: - Swift Field Offset Editor

private struct SwiftFieldOffsetEditor: View {
    @Binding var module: Transformer.SwiftFieldOffset

    var body: some View {
        EditorGrid {
            // Token-styled template editor
            EditorRow(label: "Template") {
                TemplateField(text: $module.template)
            }

            // Radix picker
            EditorRow(label: "Radix") {
                Picker("", selection: $module.useHexadecimal) {
                    Text("Decimal").tag(false)
                    Text("Hexadecimal").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            // Copyable token chips
            EditorRow(label: "Tokens") {
                FlowLayout(spacing: 8) {
                    ForEach(Transformer.SwiftFieldOffset.Token.allCases, id: \.self) { token in
                        CopyableTokenChip(token: token, placeholder: token.placeholder)
                    }
                }
            }

            // Preset buttons
            EditorRow(label: "Presets") {
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

// MARK: - Swift VTable Offset Editor

private struct SwiftVTableOffsetEditor: View {
    @Binding var module: Transformer.SwiftVTableOffset

    var body: some View {
        EditorGrid {
            // Template editor (no label)
            EditorRow(label: "Template") {
                TemplateField(text: $module.template)
            }

            // Preset buttons for template
            EditorRow(label: "Presets") {
                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftVTableOffset.Templates.all, id: \.name) { preset in
                        Button(preset.name) {
                            module.template = preset.template
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            EditorDivider()

            // Labeled template editor
            EditorRow(label: "Labeled\nTemplate") {
                TemplateField(text: $module.labeledTemplate)
            }

            // Preset buttons for labeled template
            EditorRow(label: "Presets") {
                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftVTableOffset.Templates.allLabeled, id: \.name) { preset in
                        Button(preset.name) {
                            module.labeledTemplate = preset.template
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            EditorDivider()

            // Radix picker
            EditorRow(label: "Radix") {
                Picker("", selection: $module.useHexadecimal) {
                    Text("Decimal").tag(false)
                    Text("Hexadecimal").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            // Copyable token chips
            EditorRow(label: "Tokens") {
                FlowLayout(spacing: 8) {
                    ForEach(Transformer.SwiftVTableOffset.Token.allCases, id: \.self) { token in
                        CopyableTokenChip(token: token, placeholder: token.placeholder)
                    }
                }
            }
        }
    }
}

// MARK: - Swift Member Address Editor

private struct SwiftMemberAddressEditor: View {
    @Binding var module: Transformer.SwiftMemberAddress

    var body: some View {
        EditorGrid {
            // Token-styled template editor
            EditorRow(label: "Template") {
                TemplateField(text: $module.template)
            }

            // Radix picker
            EditorRow(label: "Radix") {
                Picker("", selection: $module.useHexadecimal) {
                    Text("Decimal").tag(false)
                    Text("Hexadecimal").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            // Copyable token chips
            EditorRow(label: "Tokens") {
                FlowLayout(spacing: 8) {
                    ForEach(Transformer.SwiftMemberAddress.Token.allCases, id: \.self) { token in
                        CopyableTokenChip(token: token, placeholder: token.placeholder)
                    }
                }
            }

            // Preset buttons
            EditorRow(label: "Presets") {
                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftMemberAddress.Templates.all, id: \.name) { preset in
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

    var body: some View {
        EditorGrid {
            // Token-styled template editor
            EditorRow(label: "Template") {
                TemplateField(text: $module.template)
            }

            // Radix picker
            EditorRow(label: "Radix") {
                Picker("", selection: $module.useHexadecimal) {
                    Text("Decimal").tag(false)
                    Text("Hexadecimal").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            // Copyable token chips
            EditorRow(label: "Tokens") {
                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftTypeLayout.Token.allCases, id: \.self) { token in
                        CopyableTokenChip(token: token, placeholder: token.placeholder)
                    }
                }
            }

            // Preset buttons
            EditorRow(label: "Presets") {
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

    var body: some View {
        EditorGrid {
            // Strategy header template editor
            EditorRow(label: "Strategy\nTemplate") {
                TemplateField(text: $module.template)
            }

            // Strategy token chips
            EditorRow(label: "Tokens") {
                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftEnumLayout.Token.allCases, id: \.self) { token in
                        CopyableTokenChip(token: token, placeholder: token.placeholder)
                    }
                }
            }

            // Strategy preset buttons
            EditorRow(label: "Presets") {
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

            EditorDivider()

            // Per-case template editor
            EditorRow(label: "Case\nTemplate") {
                TemplateField(text: $module.caseTemplate)
            }

            // Case token chips
            EditorRow(label: "Tokens") {
                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftEnumLayout.CaseToken.allCases, id: \.self) { token in
                        CopyableTokenChip(token: token, placeholder: token.placeholder)
                    }
                }
            }

            // Case preset buttons
            EditorRow(label: "Presets") {
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

            EditorDivider()

            // Memory offset template editor
            EditorRow(label: "Memory\nOffset") {
                TemplateField(text: $module.memoryOffsetTemplate)
            }

            // Memory offset token chips
            EditorRow(label: "Tokens") {
                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftEnumLayout.MemoryOffsetToken.allCases, id: \.self) { token in
                        CopyableTokenChip(token: token, placeholder: token.placeholder)
                    }
                }
            }

            // Memory offset preset buttons
            EditorRow(label: "Presets") {
                FlowLayout(spacing: 6) {
                    ForEach(Transformer.SwiftEnumLayout.MemoryOffsetTemplates.all, id: \.name) { preset in
                        Button(preset.name) {
                            module.memoryOffsetTemplate = preset.template
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            EditorDivider()

            // Radix picker (shared)
            EditorRow(label: "Radix") {
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

// MARK: - Editor Layout

/// The rows of an output format editor: on macOS a grid with the labels in a
/// trailing-aligned column beside their controls; on iOS and visionOS, where a
/// settings row is too narrow for a label column, each label above its control.
private struct EditorGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
            content
        }
        #else
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        #endif
    }
}

/// One labeled row of an ``EditorGrid``. A line break in `label` is for the
/// macOS label column; above a control it reads as a space.
private struct EditorRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        GridRow {
            Text(LocalizedStringKey(label))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)

            content
        }
        #else
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(label.replacingOccurrences(of: "\n", with: " ")))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            content
        }
        #endif
    }
}

/// A divider across an ``EditorGrid``.
private struct EditorDivider: View {
    var body: some View {
        Divider()
            .gridCellColumns(2)
    }
}

// MARK: - Template Field

/// A template editor as tall as its text: the AppKit field reports the
/// height it needs, the UIKit one works it out from the width it is offered.
private struct TemplateField: View {
    @Binding var text: String

    #if os(macOS)
    @State private var height: CGFloat = 24
    #endif

    var body: some View {
        #if os(macOS)
        TokenTemplateTextField(text: $text, height: $height)
            .frame(height: max(24, height))
        #else
        TokenTemplateTextField(text: $text)
        #endif
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
