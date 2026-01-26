import SwiftUI
import SettingsKit
import Dependencies
import RuntimeViewerSettings
import RuntimeViewerCore

struct TransformerSettingsView: SettingsContent {
    @AppSettings(\.transformer)
    var config

    var body: some SettingsContent {
        SettingsGroup("Interface Transformer", .navigation) {
            SettingsForm {
                // MARK: - C Type Module
                Section {
                    Toggle("Enable C Type Replacement", isOn: $config.cType.isEnabled)
                } footer: {
                    Text("Replace C primitive types with custom types in ObjC interfaces.")
                }

                if config.cType.isEnabled {
                    Section {
                        CTypeEditor(module: $config.cType)
                    } header: {
                        Text("Type Replacements")
                    } footer: {
                        Text("Configure which C types to replace. Leave empty to use original.")
                    }

                    Section {
                        CTypePresets(module: $config.cType)
                    } header: {
                        Text("Presets")
                    }
                }

                Divider().padding(.vertical, 8)

                // MARK: - Field Offset Module
                Section {
                    Toggle("Enable Field Offset Format", isOn: $config.fieldOffset.isEnabled)
                } footer: {
                    Text("Customize field offset comment format in Swift interfaces.")
                }

                if config.fieldOffset.isEnabled {
                    Section {
                        FieldOffsetEditor(module: $config.fieldOffset)
                    } header: {
                        Text("Output Format")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Available tokens:")
                            ForEach(Transformer.FieldOffset.Token.allCases, id: \.self) { token in
                                Text("• \(token.placeholder) - \(token.displayName)")
                                    .font(.caption)
                            }
                        }
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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Transformer.CType.Pattern.allCases, id: \.self) { pattern in
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
                            get: { module.replacements[pattern] ?? "" },
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
                    .frame(width: 120)
                }
            }
        }
    }
}

// MARK: - C Type Presets

private struct CTypePresets: View {
    @Binding var module: Transformer.CType

    var body: some View {
        HStack(spacing: 12) {
            Button("stdint.h") {
                module.replacements = Transformer.CType.Presets.stdint
            }
            .help("uint32_t, int64_t, etc.")

            Button("Foundation") {
                module.replacements = Transformer.CType.Presets.foundation
            }
            .help("CGFloat, NSInteger, etc.")

            Spacer()

            Button("Clear All") {
                module.replacements.removeAll()
            }
            .foregroundStyle(.red)
        }
    }
}

// MARK: - Field Offset Editor

private struct FieldOffsetEditor: View {
    @Binding var module: Transformer.FieldOffset

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Template input
            VStack(alignment: .leading, spacing: 4) {
                Text("Template")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Template", text: $module.template)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            // Preset buttons
            HStack(spacing: 8) {
                ForEach(Transformer.FieldOffset.Templates.all, id: \.name) { preset in
                    Button(preset.name) {
                        module.template = preset.template
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
                    Text(module.render(start: 0, end: 8))
                }
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
