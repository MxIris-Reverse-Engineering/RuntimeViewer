#if os(macOS)

import SwiftUI
import Dependencies
import RuntimeViewerSettings

struct BackgroundIndexingSettingsView: View {
    @AppSettings(\.backgroundIndexing)
    var settings

    var body: some View {
        SettingsForm {
            Section {
                Toggle("Enable Background Indexing", isOn: $settings.isEnabled)
            } footer: {
                Text("When enabled, Runtime Viewer parses ObjC and Swift metadata for the dependency closure of loaded images in the background so that lookups are instant.")
            }

            Section {
                Stepper(value: $settings.depth, in: 1...5) {
                    LabeledContent("Depth", value: "\(settings.depth)")
                }
                .disabled(!settings.isEnabled)

                Stepper(value: $settings.maxConcurrency, in: 1...8) {
                    LabeledContent("Max Concurrent Tasks", value: "\(settings.maxConcurrency)")
                }
                .disabled(!settings.isEnabled)
            } header: {
                Text("Indexing")
            } footer: {
                Text("Depth controls how many levels of dependencies to index starting from each root image. Max concurrent tasks limits how many images are indexed in parallel; higher values finish faster but use more CPU.")
            }
        }
    }
}

#endif
