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
                Section {
                    Toggle("Enable Interface Transformers", isOn: $settings.isEnabled)
                } footer: {
                    Text("When enabled, interface output will be transformed according to the rules below.")
                }

                Section {
                    Toggle("Use stdint.h Types", isOn: $settings.useStdintReplacements)
                        .disabled(!settings.isEnabled)
                } header: {
                    Text("Predefined Replacements")
                } footer: {
                    Text("Replace C integer types with their stdint.h equivalents (e.g., unsigned int → uint32_t).")
                }

                Section {
                    CustomReplacementsView(
                        replacements: $settings.customReplacements,
                        isEnabled: settings.isEnabled
                    )
                } header: {
                    Text("Custom Type Replacements")
                } footer: {
                    Text("Add custom type replacement rules. The pattern will be matched exactly and replaced with the specified string.")
                }
            }
        } icon: {
            SettingsIcon(symbol: "arrow.triangle.2.circlepath", color: .clear)
        }
    }
}

// MARK: - Custom Replacements View

private struct CustomReplacementsView: View {
    @Binding var replacements: [CTypeReplacement]
    let isEnabled: Bool

    @State private var newPattern: String = ""
    @State private var newReplacement: String = ""
    @State private var showingAddSheet: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if replacements.isEmpty {
                Text("No custom replacements configured.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(replacements) { replacement in
                    ReplacementRow(
                        replacement: replacement,
                        isEnabled: isEnabled,
                        onToggle: { toggleReplacement(replacement) },
                        onDelete: { deleteReplacement(replacement) }
                    )
                }
            }

            Button {
                showingAddSheet = true
            } label: {
                Label("Add Replacement", systemImage: "plus")
            }
            .disabled(!isEnabled)
        }
        .sheet(isPresented: $showingAddSheet) {
            AddReplacementSheet(
                pattern: $newPattern,
                replacement: $newReplacement,
                onAdd: addReplacement,
                onCancel: { showingAddSheet = false }
            )
        }
    }

    private func toggleReplacement(_ replacement: CTypeReplacement) {
        if let index = replacements.firstIndex(where: { $0.id == replacement.id }) {
            var updated = replacement
            updated.isEnabled.toggle()
            replacements[index] = updated
        }
    }

    private func deleteReplacement(_ replacement: CTypeReplacement) {
        replacements.removeAll { $0.id == replacement.id }
    }

    private func addReplacement() {
        guard !newPattern.isEmpty, !newReplacement.isEmpty else { return }
        let replacement = CTypeReplacement(
            pattern: newPattern,
            replacement: newReplacement
        )
        replacements.append(replacement)
        newPattern = ""
        newReplacement = ""
        showingAddSheet = false
    }
}

// MARK: - Replacement Row

private struct ReplacementRow: View {
    let replacement: CTypeReplacement
    let isEnabled: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { replacement.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .disabled(!isEnabled)

            VStack(alignment: .leading, spacing: 2) {
                Text(replacement.pattern)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(replacement.isEnabled && isEnabled ? .primary : .secondary)

                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(replacement.replacement)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add Replacement Sheet

private struct AddReplacementSheet: View {
    @Binding var pattern: String
    @Binding var replacement: String
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Type Replacement")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pattern")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g., unsigned int", text: $pattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Replacement")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g., uint32_t", text: $replacement)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    onAdd()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pattern.isEmpty || replacement.isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }
}
