#if os(macOS)

import SwiftUI
import Dependencies
import RuntimeViewerSettings
import RuntimeViewerEngineManagement
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
                Text("Master switch for all background indexing. When off, neither sub-mode below runs. Max Concurrent Tasks limits how many images both sub-modes together index at the same time. Higher values finish sooner, but an image you open while they run loads more slowly; no new background work starts until it has loaded.")
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
/// Recursive switch, delete button, and under the field a labeled engine
/// menu), plus a trailing Add button. The list is order-preserving —
/// duplicate / blank entries are accepted and only filtered at the
/// resolution step in the coordinator.
///
/// The engine menu has a line of its own because an engine's name has no
/// length limit — an attached process is shown by its process name — and on
/// the field's line a long name squeezed the field.
private struct AlwaysIndexSection: View {
    @Binding var isEnabled: Bool
    @Binding var entries: [RuntimeViewerSettings.Settings.Indexing.AlwaysIndexEntry]
    let masterEnabled: Bool

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    /// The engines connected now, grouped by host as the toolbar's source
    /// switcher groups them.
    @State private var connectedEngineSections: [EngineMenuSection] = []

    private var entryFieldsDisabled: Bool { !masterEnabled || !isEnabled }

    var body: some View {
        Section {
            Toggle("Always Index Listed Images", isOn: $isEnabled)
                .disabled(!masterEnabled)

            ForEach(entries.indices, id: \.self) { index in
                let entryEnabled = entries.indices.contains(index) ? entries[index].isEnabled : false
                VStack(alignment: .identifierFieldLeading, spacing: 6) {
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
                        .alignmentGuide(.identifierFieldLeading) { dimensions in dimensions[.leading] }
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
                    HStack(spacing: 6) {
                        Text("Indexed on")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        AlwaysIndexEngineMenu(
                            entry: Binding(
                                get: { entries.indices.contains(index) ? entries[index] : .default },
                                set: { newValue in
                                    guard entries.indices.contains(index) else { return }
                                    entries[index] = newValue
                                }
                            ),
                            connectedEngineSections: connectedEngineSections
                        )
                        .disabled(entryFieldsDisabled || !entryEnabled)
                    }
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
            Text("Images listed here are indexed in the background whenever a document opens, the runtime engine changes, or this list changes. Each entry may be a full path (starting with \"/\") or just the image's file name (matched against loaded images by last path component). Entries that don't match any loaded image are silently skipped. The leading switch enables or disables the row without deleting it — a disabled row is skipped, and a batch already running finishes naturally. The Indexed on menu under each image picks the runtime engines the row is indexed on: All Engines, which includes engines connected later, or only the engines checked, which are remembered while they are not connected. A process attached on this Mac is matched by its name, so the choice still holds after it relaunches. Taking an engine off a row works like disabling the row on that engine. The Recursive switch additionally indexes the image's full dependency closure using the Heuristic Discovery depth above; when off, only the image itself is indexed.")
        }
        .onReceive(runtimeEngineManager.$runtimeEngineSections) { sections in
            connectedEngineSections = sections.map(EngineMenuSection.init(section:))
        }
    }
}

extension HorizontalAlignment {
    private enum IdentifierFieldLeading: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[.leading]
        }
    }

    /// The leading edge of an always-index row's identifier field, which the
    /// engine menu's line below it starts at.
    fileprivate static let identifierFieldLeading = HorizontalAlignment(IdentifierFieldLeading.self)
}

/// One host's engines in an always-index row's engine menu.
private struct EngineMenuSection: Identifiable {
    let id: String
    let hostName: String
    /// One reference per key: two engines that share a key — two attached
    /// processes of one name — are one choice.
    let engines: [RuntimeViewerSettings.Settings.Indexing.EngineReference]

    init(section: RuntimeEngineSection) {
        id = section.hostID
        hostName = section.hostName
        var seenKeys: Set<String> = []
        engines = section.engines
            .map(RuntimeViewerSettings.Settings.Indexing.EngineReference.init(engine:))
            .filter { seenKeys.insert($0.key).inserted }
    }
}

/// The engine menu of one always-index row: All Engines at the top, then the
/// connected engines by host, then the engines the row is limited to that are
/// not connected now.
private struct AlwaysIndexEngineMenu: View {
    @Binding var entry: RuntimeViewerSettings.Settings.Indexing.AlwaysIndexEntry
    let connectedEngineSections: [EngineMenuSection]

    var body: some View {
        Menu {
            Section {
                Toggle("All Engines", isOn: $entry.appliesToAllEngines)
            }
            ForEach(connectedEngineSections) { section in
                Section(section.hostName) {
                    ForEach(section.engines, id: \.key) { engine in
                        Toggle(engine.name, isOn: selectionBinding(for: engine))
                    }
                }
            }
            if !disconnectedEngines.isEmpty {
                Section("Not Connected") {
                    ForEach(disconnectedEngines, id: \.key) { engine in
                        Toggle(
                            engine.hostName.isEmpty ? engine.name : "\(engine.name) — \(engine.hostName)",
                            isOn: selectionBinding(for: engine)
                        )
                    }
                }
            }
        } label: {
            Text(title)
        }
        .fixedSize()
        .help("The runtime engines this image is indexed on. All Engines includes engines connected later.")
    }

    private var title: String {
        if entry.appliesToAllEngines {
            return "All Engines"
        }
        switch entry.engines.count {
        case 0:
            return "No Engines"
        case 1:
            return entry.engines[0].name
        default:
            return "\(entry.engines.count) Engines"
        }
    }

    /// The engines the row is limited to that no connected engine answers to.
    /// None while the row applies to all engines: the engines it remembers
    /// for later are not a choice in effect.
    private var disconnectedEngines: [RuntimeViewerSettings.Settings.Indexing.EngineReference] {
        guard !entry.appliesToAllEngines else { return [] }
        let connectedKeys = Set(connectedEngineSections.flatMap { $0.engines.map(\.key) })
        return entry.engines.filter { !connectedKeys.contains($0.key) }
    }

    private func selectionBinding(for engine: RuntimeViewerSettings.Settings.Indexing.EngineReference) -> Binding<Bool> {
        Binding(
            get: { entry.selectsEngine(withKey: engine.key) },
            set: { isSelected in entry.setEngine(engine, isSelected: isSelected) }
        )
    }
}

#endif
