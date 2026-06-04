#if os(macOS)

import SwiftUI
import Dependencies
import RuntimeViewerSettings

struct IndexingSettingsView: View {
    @AppSettings(\.indexing)
    var indexing

    private static let maxConcurrencyUpperBound = max(1, ProcessInfo.processInfo.processorCount)

    var body: some View {
        SettingsForm {
            Section {
                Toggle("Enable Background Indexing", isOn: $indexing.backgroundMode.isEnabled)
            } header: {
                Text("Background Indexing")
            } footer: {
                Text("When enabled, Runtime Viewer parses ObjC and Swift metadata for the dependency closure of loaded images in the background so that lookups are instant.")
            }

            Section {
                Stepper("Depth", value: $indexing.backgroundMode.depth.asDouble, in: 1...5, format: .number.precision(.fractionLength(0)))
                .disabled(!indexing.backgroundMode.isEnabled)

                Stepper("Max Concurrent Tasks", value: $indexing.backgroundMode.maxConcurrency.asDouble, in: 1...Self.maxConcurrencyUpperBound.double, format: .number.precision(.fractionLength(0)))
                .disabled(!indexing.backgroundMode.isEnabled)
            } footer: {
                Text("Depth controls how many levels of dependencies to index starting from each root image. Max concurrent tasks limits how many images are indexed in parallel; higher values finish faster but use more CPU.")
            }

            AlwaysIndexSection(entries: $indexing.alwaysIndexEntries)
        }
    }
}

/// Editor section for `Settings.Indexing.alwaysIndexEntries`. Renders each
/// entry as an editable row with an identifier field, a "Follow Dependencies"
/// toggle, and a delete button, plus a trailing "Add" button. The list is
/// order-preserving — duplicate / blank entries are accepted and only
/// filtered at the resolution step in the coordinator.
private struct AlwaysIndexSection: View {
    @Binding var entries: [RuntimeViewerSettings.Settings.Indexing.AlwaysIndexEntry]

    var body: some View {
        Section {
            ForEach(entries.indices, id: \.self) { index in
                HStack {
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
                    Toggle(
                        "Follow Dependencies",
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
                    Button {
                        guard entries.indices.contains(index) else { return }
                        entries.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Button {
                entries.append(.default)
            } label: {
                Label("Add Image", systemImage: "plus.circle")
            }
        } header: {
            Text("Always Index")
        } footer: {
            Text("These images are indexed in the background whenever a document opens, the runtime engine changes, or this list changes. Each entry may be a full path (starting with \"/\") or just the image's file name (matched against loaded images by last path component). Entries that don't match any loaded image are silently skipped. Enable Follow Dependencies on a row to also index the image's full dependency closure using the global depth above; otherwise only the image itself is indexed.")
        }
    }
}

#endif
