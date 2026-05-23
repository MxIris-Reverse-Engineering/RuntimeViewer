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
        }
    }
}

#endif
