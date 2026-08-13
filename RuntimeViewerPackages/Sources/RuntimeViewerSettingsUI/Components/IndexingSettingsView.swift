#if os(macOS)

import SwiftUI
import Dependencies
import RuntimeViewerSettings
import UIFoundationSettingsUI

struct IndexingSettingsView: View {
    @AppSettings(\.indexing)
    var indexing

    private static let maxConcurrencyUpperBound = max(1, ProcessInfo.processInfo.processorCount)

    var body: some View {
        SettingsForm {
            Section {
                Toggle("Enable Background Indexing", isOn: $indexing.isEnabled)

                Stepper(
                    "Max Concurrent Tasks",
                    value: $indexing.maxConcurrency.asDouble,
                    in: 1...Self.maxConcurrencyUpperBound.double,
                    format: .number.precision(.fractionLength(0))
                )
                .disabled(!indexing.isEnabled)
            } header: {
                Text("Background Indexing")
            } footer: {
                Text("Master switch for all background indexing. When off, neither sub-mode below runs. Max Concurrent Tasks limits how many images both sub-modes can index in parallel; higher values finish faster but use more CPU.")
            }

            Section {
                Toggle("Discover from Main Executable", isOn: $indexing.heuristic.isEnabled)
                    .disabled(!indexing.isEnabled)

                Stepper(
                    "Depth",
                    value: $indexing.heuristic.depth.asDouble,
                    in: 1...5,
                    format: .number.precision(.fractionLength(0))
                )
                .disabled(!indexing.isEnabled || !indexing.heuristic.isEnabled)
            } header: {
                Text("Heuristic Discovery")
            } footer: {
                Text("When a document opens, Runtime Viewer parses ObjC and Swift metadata for the main executable and its dependency closure up to the configured depth so lookups are instant. Images dlopen'd after the initial sweep are not auto-indexed.")
            }

            AlwaysIndexSection(
                isEnabled: $indexing.custom.isEnabled,
                entries: $indexing.custom.entries,
                masterEnabled: indexing.isEnabled
            )
        }
    }
}

/// Editor section for `Settings.Indexing.custom`. Renders the custom toggle,
/// each entry as an editable row (enable switch, identifier field, labeled
/// Recursive switch, delete button), plus a trailing Add button. The list is
/// order-preserving — duplicate / blank entries are accepted and only
/// filtered at the resolution step in the coordinator.
private struct AlwaysIndexSection: View {
    @Binding var isEnabled: Bool
    @Binding var entries: [RuntimeViewerSettings.Settings.Indexing.AlwaysIndexEntry]
    let masterEnabled: Bool

    private var entryFieldsDisabled: Bool { !masterEnabled || !isEnabled }

    var body: some View {
        Section {
            Toggle("Always Index Listed Images", isOn: $isEnabled)
                .disabled(!masterEnabled)

            ForEach(entries.indices, id: \.self) { index in
                let entryEnabled = entries.indices.contains(index) ? entries[index].isEnabled : false
                HStack {
                    Toggle(
                        "Index This Image",
                        isOn: Binding(
                            get: { entries.indices.contains(index) ? entries[index].isEnabled : false },
                            set: { newValue in
                                guard entries.indices.contains(index) else { return }
                                entries[index].isEnabled = newValue
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Index this image. When off, the entry is kept in the list but skipped; a batch already running finishes naturally.")
                    TextField(
                        "imagePath or imageName",
                        text: Binding(
                            get: { entries.indices.contains(index) ? entries[index].identifier : "" },
                            set: { newValue in
                                guard entries.indices.contains(index) else { return }
                                entries[index].identifier = newValue
                            }
                        )
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .disabled(entryFieldsDisabled || !entryEnabled)
                    Text("Recursive")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Toggle(
                        "Recursive",
                        isOn: Binding(
                            get: { entries.indices.contains(index) ? entries[index].followDependencies : false },
                            set: { newValue in
                                guard entries.indices.contains(index) else { return }
                                entries[index].followDependencies = newValue
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Recursively index the image's dependency closure using the Heuristic Discovery depth above. When off, only the image itself is indexed.")
                    .disabled(entryFieldsDisabled || !entryEnabled)
                    Button {
                        guard entries.indices.contains(index) else { return }
                        entries.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .disabled(entryFieldsDisabled)
            }

            Button {
                entries.append(.default)
            } label: {
                Label("Add Image", systemImage: "plus.circle")
            }
            .disabled(entryFieldsDisabled)
        } header: {
            Text("Always Index")
        } footer: {
            Text("Images listed here are indexed in the background whenever a document opens, the runtime engine changes, or this list changes. Each entry may be a full path (starting with \"/\") or just the image's file name (matched against loaded images by last path component). Entries that don't match any loaded image are silently skipped. The leading switch enables or disables the row without deleting it — a disabled row is skipped, and a batch already running finishes naturally. The Recursive switch additionally indexes the image's full dependency closure using the Heuristic Discovery depth above; when off, only the image itself is indexed.")
        }
    }
}

#endif
