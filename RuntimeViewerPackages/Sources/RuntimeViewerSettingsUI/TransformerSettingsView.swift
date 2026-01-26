import SwiftUI
import SettingsKit
import Dependencies
import RuntimeViewerSettings
import RuntimeViewerCore

struct TransformerSettingsView: SettingsContent {
    @AppSettings(\.transformer)
    var settings

    var body: some SettingsContent {
        SettingsGroup("Interface Transformer", .navigation) {
            SettingsForm {
                // MARK: - C Type Transformer Section
                Section {
                    Toggle("Enable C Type Replacement", isOn: $settings.cType.isEnabled)
                } footer: {
                    Text("Replace C primitive types with custom types in ObjC interfaces.")
                }

                if settings.cType.isEnabled {
                    Section {
                        CTypeReplacementEditor(config: $settings.cType)
                    } header: {
                        Text("Type Replacements")
                    } footer: {
                        Text("Configure which C types to replace. Leave empty to use original type.")
                    }

                    Section {
                        PresetButtons(config: $settings.cType)
                    } header: {
                        Text("Presets")
                    }
                }

                Divider()
                    .padding(.vertical, 8)

                // MARK: - Swift Field Offset Transformer Section
                Section {
                    Toggle("Enable Field Offset Format", isOn: $settings.swiftFieldOffset.isEnabled)
                } footer: {
                    Text("Customize the format of field offset comments in Swift interfaces.")
                }

                if settings.swiftFieldOffset.isEnabled {
                    Section {
                        SwiftFieldOffsetEditor(config: $settings.swiftFieldOffset)
                    } header: {
                        Text("Output Format")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Available tokens:")
                            Text("• ${startOffset} - Field start offset")
                                .font(.caption)
                            Text("• ${endOffset} - Field end offset")
                                .font(.caption)
                        }
                    }
                }
            }
        } icon: {
            SettingsIcon(symbol: "arrow.triangle.2.circlepath", color: .clear)
        }
    }
}

// MARK: - C Type Replacement Editor

private struct CTypeReplacementEditor: View {
    @Binding var config: CTypeTransformerConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(CTypeTransformerConfig.Pattern.allCases, id: \.self) { pattern in
                HStack {
                    Text(pattern.displayName)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 140, alignment: .leading)

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    TextField(
                        "Original",
                        text: Binding(
                            get: { config.replacements[pattern] ?? "" },
                            set: { newValue in
                                if newValue.isEmpty {
                                    config.replacements.removeValue(forKey: pattern)
                                } else {
                                    config.replacements[pattern] = newValue
                                }
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 120)
                }
            }
        }
    }
}

// MARK: - Preset Buttons

private struct PresetButtons: View {
    @Binding var config: CTypeTransformerConfig

    var body: some View {
        HStack(spacing: 12) {
            Button("stdint.h") {
                config.replacements = CTypeTransformerConfig.stdintPreset
            }
            .help("uint32_t, int64_t, etc.")

            Button("Foundation") {
                config.replacements = CTypeTransformerConfig.foundationPreset
            }
            .help("CGFloat, NSInteger, etc.")

            Spacer()

            Button("Clear All") {
                config.replacements.removeAll()
            }
            .foregroundStyle(.red)
        }
    }
}

// MARK: - Swift Field Offset Editor

private struct SwiftFieldOffsetEditor: View {
    @Binding var config: SwiftFieldOffsetTransformerConfig

    @State private var previewStartOffset = 0
    @State private var previewEndOffset = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Template input
            VStack(alignment: .leading, spacing: 4) {
                Text("Template")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Template", text: $config.template)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            // Preset templates
            HStack(spacing: 8) {
                ForEach(presetTemplates, id: \.0) { name, template in
                    Button(name) {
                        config.template = template
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // Live preview
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("// ")
                        .foregroundStyle(.secondary)
                    Text(config.render(startOffset: previewStartOffset, endOffset: previewEndOffset))
                }
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var presetTemplates: [(String, String)] {
        [
            ("Range", SwiftFieldOffsetTransformerConfig.rangeTemplate),
            ("Labeled", SwiftFieldOffsetTransformerConfig.labeledTemplate),
            ("Interval", SwiftFieldOffsetTransformerConfig.intervalTemplate),
            ("Start Only", SwiftFieldOffsetTransformerConfig.startOnlyTemplate),
        ]
    }
}
