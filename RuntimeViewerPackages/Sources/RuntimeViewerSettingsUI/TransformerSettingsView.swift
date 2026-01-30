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
                        HStack {
                            Text("Type Replacements")
                            Spacer()
                            CTypePresets(module: $config.cType)
                        }
                    }
                }

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
                    Text(pattern.displayName)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                        .lineLimit(1)
                        .fixedSize()

                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    TextField("Replacement", text: Binding(
                        get: { module.replacements[pattern] ?? "" },
                        set: { newValue in
                            if newValue.isEmpty {
                                module.replacements.removeValue(forKey: pattern)
                            } else {
                                module.replacements[pattern] = newValue
                            }
                        }
                    ))
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
            Button("stdint.h") {
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

            Button("Clear") {
                module.replacements.removeAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - Field Offset Editor

private struct FieldOffsetEditor: View {
    @Binding var module: Transformer.FieldOffset

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Template input
            HStack {
                Text("Template")
                    .foregroundStyle(.secondary)
                TextField("e.g. ${startOffset} ..< ${endOffset}", text: $module.template)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            // Preset buttons
            HStack(spacing: 8) {
                Text("Presets")
                    .foregroundStyle(.secondary)
                ForEach(Transformer.FieldOffset.Templates.all, id: \.name) { preset in
                    Button(preset.name) {
                        module.template = preset.template
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // Tokens + Preview
            HStack(alignment: .top, spacing: 16) {
                // Available tokens
                VStack(alignment: .leading, spacing: 4) {
                    Text("Available Tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Transformer.FieldOffset.Token.allCases, id: \.self) { token in
                        HStack(spacing: 4) {
                            Text(token.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                            Text(token.placeholder)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }

                Spacer()

                // Live preview
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        Text("// ")
                            .foregroundStyle(.secondary)
                        Text(module.transform(.init(startOffset: 0, endOffset: 8)))
                    }
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}
