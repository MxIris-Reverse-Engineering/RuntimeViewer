#if os(macOS)

import AppKit
import SwiftUI
import Dependencies
import RuntimeViewerSettings

struct ThemeSettingsView: View {
    @AppSettings(\.theme)
    private var theme

    @Environment(\.colorScheme)
    private var colorScheme

    @State private var editingPreset: RuntimeViewerSettings.Settings.Theme.Preset?

    private static let minimumFontSize: Double = 8
    private static let maximumFontSize: Double = 32

    var body: some View {
        SettingsForm {
            Section {
                ForEach(theme.allPresets) { preset in
                    ThemeRow(
                        preset: preset,
                        isSelected: preset.id == theme.selectedPresetID,
                        onSelect: { theme.selectedPresetID = preset.id },
                        onEdit: preset.isBuiltin ? nil : { editingPreset = preset },
                        onDuplicate: { duplicate(preset) },
                        onDelete: preset.isBuiltin ? nil : { delete(preset) }
                    )
                }
            } header: {
                Text("Themes")
            } footer: {
                Text("Colors adapt to the appearance selected in General. Built-in presets are read-only; duplicate one to customize its colors.")
            }

            Section {
                LabeledContent("Font Size") {
                    Stepper(
                        "",
                        value: $theme.fontSize,
                        in: Self.minimumFontSize...Self.maximumFontSize,
                        step: 1,
                        format: .number.precision(.fractionLength(0))
                    )
                    .labelsHidden()
                }
            } header: {
                Text("Editor")
            }
        }
        .sheet(item: $editingPreset) { preset in
            ThemeDetailsView(
                preset: preset,
                initialAppearance: colorScheme == .dark ? .dark : .light
            ) { updated in
                guard let index = theme.customPresets.firstIndex(where: { $0.id == updated.id }) else { return }
                theme.customPresets[index] = updated
            }
        }
    }

    // MARK: - Actions

    private func duplicate(_ preset: RuntimeViewerSettings.Settings.Theme.Preset) {
        var copy = preset
        copy.id = UUID().uuidString
        copy.name = uniquePresetName(basedOn: "\(preset.name) copy")
        copy.isBuiltin = false
        theme.customPresets.append(copy)
        theme.selectedPresetID = copy.id
        editingPreset = copy
    }

    private func uniquePresetName(basedOn base: String) -> String {
        let existing = Set(theme.allPresets.map(\.name))
        if !existing.contains(base) { return base }
        var counter = 2
        while existing.contains("\(base) \(counter)") {
            counter += 1
        }
        return "\(base) \(counter)"
    }

    private func delete(_ preset: RuntimeViewerSettings.Settings.Theme.Preset) {
        theme.customPresets.removeAll { $0.id == preset.id }
        if theme.selectedPresetID == preset.id {
            theme.selectedPresetID = RuntimeViewerSettings.Settings.Theme.builtinXcodePresetID
        }
    }
}

// MARK: - Theme Row

private struct ThemeRow: View {
    let preset: RuntimeViewerSettings.Settings.Theme.Preset
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: (() -> Void)?
    let onDuplicate: () -> Void
    let onDelete: (() -> Void)?

    @Environment(\.colorScheme)
    private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                if preset.isBuiltin {
                    Text("Built-in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            ThemeColorPreview(preset: preset, colorScheme: colorScheme)

            Menu {
                if !isSelected {
                    Button("Set as Active", action: onSelect)
                }
                if let onEdit {
                    Button("Edit…", action: onEdit)
                }
                Button("Duplicate", action: onDuplicate)
                if let onDelete {
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Color Preview

private struct ThemeColorPreview: View {
    let preset: RuntimeViewerSettings.Settings.Theme.Preset
    let colorScheme: ColorScheme

    private var styles: [RuntimeViewerSettings.Settings.Theme.Style] {
        [preset.keyword, preset.typeName, preset.declaration, preset.comment, preset.number, preset.error]
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(styles.enumerated()), id: \.offset) { _, style in
                RoundedRectangle(cornerRadius: 2)
                    .fill(style.color(for: colorScheme))
                    .frame(width: 12, height: 12)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(preset.background.color(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Theme Details (Color Editor)

private enum EditingAppearance: String, CaseIterable, Identifiable {
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }
}

private struct ThemeDetailsView: View {
    private struct Slot: Identifiable {
        let title: String
        let keyPath: WritableKeyPath<RuntimeViewerSettings.Settings.Theme.Preset, RuntimeViewerSettings.Settings.Theme.Style>
        let supportsTraits: Bool
        var id: String { title }
    }

    private static let slots: [Slot] = [
        Slot(title: "Background", keyPath: \.background, supportsTraits: false),
        Slot(title: "Selection", keyPath: \.selection, supportsTraits: false),
        Slot(title: "Text", keyPath: \.text, supportsTraits: true),
        Slot(title: "Keyword", keyPath: \.keyword, supportsTraits: true),
        Slot(title: "Type Name", keyPath: \.typeName, supportsTraits: true),
        Slot(title: "Declaration", keyPath: \.declaration, supportsTraits: true),
        Slot(title: "Comment", keyPath: \.comment, supportsTraits: true),
        Slot(title: "Number", keyPath: \.number, supportsTraits: false),
        Slot(title: "Error", keyPath: \.error, supportsTraits: false),
    ]

    let onUpdate: (RuntimeViewerSettings.Settings.Theme.Preset) -> Void

    @State private var draft: RuntimeViewerSettings.Settings.Theme.Preset
    @State private var editingAppearance: EditingAppearance
    @State private var pendingFlushTask: Task<Void, Never>?

    @Environment(\.dismiss)
    private var dismiss

    private static let draftFlushDelay: Duration = .milliseconds(150)

    init(
        preset: RuntimeViewerSettings.Settings.Theme.Preset,
        initialAppearance: EditingAppearance,
        onUpdate: @escaping (RuntimeViewerSettings.Settings.Theme.Preset) -> Void
    ) {
        self.onUpdate = onUpdate
        self._draft = State(initialValue: preset)
        self._editingAppearance = State(initialValue: initialAppearance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                Spacer()

                Picker("", selection: $editingAppearance) {
                    ForEach(EditingAppearance.allCases) { appearance in
                        Text(appearance.rawValue).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            previewBox

            Form {
                ForEach(Self.slots) { slot in
                    LabeledContent(slot.title) {
                        HStack(spacing: 6) {
                            if slot.supportsTraits {
                                Toggle(isOn: boldBinding(slot.keyPath)) {
                                    Image(systemName: "bold")
                                }
                                .toggleStyle(.button)
                                .help("Bold")

                                Toggle(isOn: italicBinding(slot.keyPath)) {
                                    Image(systemName: "italic")
                                }
                                .toggleStyle(.button)
                                .help("Italic")
                            }

                            ColorPicker("", selection: colorBinding(slot.keyPath), supportsOpacity: true)
                                .labelsHidden()
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") {
                    pendingFlushTask?.cancel()
                    pendingFlushTask = nil
                    onUpdate(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 600)
        .onChange(of: draft) { _, newValue in
            pendingFlushTask?.cancel()
            pendingFlushTask = Task { @MainActor in
                try? await Task.sleep(for: Self.draftFlushDelay)
                guard !Task.isCancelled else { return }
                onUpdate(newValue)
            }
        }
        .onDisappear {
            pendingFlushTask?.cancel()
            pendingFlushTask = nil
        }
    }

    // MARK: Preview

    private var previewBox: some View {
        let background = variant(\.background)
        return VStack(alignment: .leading, spacing: 2) {
            (run("@interface ", \.keyword) + run("RuntimeObject", \.declaration) + run(" : ", \.text) + run("NSObject", \.typeName))
            run("// A sample comment", \.comment)
            (run("@property ", \.keyword) + run("(", \.text) + run("nonatomic", \.keyword) + run(") ", \.text) + run("NSInteger", \.typeName) + run(" count", \.declaration) + run(";", \.text))
            (run("- (", \.text) + run("void", \.keyword) + run(") ", \.text) + run("reloadWithLimit", \.declaration) + run(":(", \.text) + run("NSInteger", \.typeName) + run(")", \.text) + run("limit", \.declaration) + run(";", \.text))
            (run("struct ", \.keyword) + run("Metrics", \.declaration) + run(" { ", \.text) + run("char", \.keyword) + run(" name", \.declaration) + run("[", \.text) + run("404", \.number) + run("]; }", \.text))
        }
        .font(.system(size: 13, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 1))
    }

    private func run(
        _ string: String,
        _ keyPath: WritableKeyPath<RuntimeViewerSettings.Settings.Theme.Preset, RuntimeViewerSettings.Settings.Theme.Style>
    ) -> Text {
        let style = draft[keyPath: keyPath]
        var text = Text(string).foregroundColor(variant(keyPath))
        if style.isBold { text = text.bold() }
        if style.isItalic { text = text.italic() }
        return text
    }

    // MARK: Bindings

    private func variant(
        _ keyPath: WritableKeyPath<RuntimeViewerSettings.Settings.Theme.Preset, RuntimeViewerSettings.Settings.Theme.Style>
    ) -> Color {
        let style = draft[keyPath: keyPath]
        return (editingAppearance == .light ? style.light : style.dark).color
    }

    private func colorBinding(
        _ keyPath: WritableKeyPath<RuntimeViewerSettings.Settings.Theme.Preset, RuntimeViewerSettings.Settings.Theme.Style>
    ) -> Binding<Color> {
        Binding(
            get: { variant(keyPath) },
            set: { newColor in
                let colorValue = RuntimeViewerSettings.Settings.Theme.ColorValue.from(newColor)
                if editingAppearance == .light {
                    draft[keyPath: keyPath].light = colorValue
                } else {
                    draft[keyPath: keyPath].dark = colorValue
                }
            }
        )
    }

    private func boldBinding(
        _ keyPath: WritableKeyPath<RuntimeViewerSettings.Settings.Theme.Preset, RuntimeViewerSettings.Settings.Theme.Style>
    ) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: keyPath].isBold },
            set: { draft[keyPath: keyPath].isBold = $0 }
        )
    }

    private func italicBinding(
        _ keyPath: WritableKeyPath<RuntimeViewerSettings.Settings.Theme.Preset, RuntimeViewerSettings.Settings.Theme.Style>
    ) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: keyPath].isItalic },
            set: { draft[keyPath: keyPath].isItalic = $0 }
        )
    }
}

// MARK: - Color Conversion

extension RuntimeViewerSettings.Settings.Theme.ColorValue {
    fileprivate var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    fileprivate static func from(_ color: Color) -> Self {
        guard let sRGBColor = NSColor(color).usingColorSpace(.sRGB) else {
            return .rgb(0, 0, 0)
        }
        return .init(
            red: Double(sRGBColor.redComponent),
            green: Double(sRGBColor.greenComponent),
            blue: Double(sRGBColor.blueComponent),
            alpha: Double(sRGBColor.alphaComponent)
        )
    }
}

extension RuntimeViewerSettings.Settings.Theme.Style {
    fileprivate func color(for colorScheme: ColorScheme) -> Color {
        (colorScheme == .dark ? dark : light).color
    }
}

#endif
