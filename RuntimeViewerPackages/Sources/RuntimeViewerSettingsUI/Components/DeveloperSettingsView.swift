#if os(macOS)

import SwiftUI
import RuntimeViewerSettings
import UIFoundationSettingsUI

/// Settings › Developer, shown in Debug builds only; see `Settings.Developer`.
struct DeveloperSettingsView: View {
    @AppSettings(\.developer)
    var developer

    /// One value under the loading plate's 100-millisecond grace period, so a short load can be
    /// checked to stay plate-free, and the rest over it.
    private static let contentLoadingDelays: [TimeInterval] = [0.05, 0.3, 1, 2, 5]

    var body: some View {
        SettingsForm {
            Section {
                Toggle("Enable Developer Options", isOn: $developer.isEnabled)
            } footer: {
                Text("Master switch for everything on this page. When off, none of the options below takes effect, but each keeps its value for the next time it is turned on.")
            }

            Section {
                Picker("Delay", selection: $developer.contentLoadingDelay) {
                    Text("Off").tag(TimeInterval(0))
                    ForEach(Self.contentLoadingDelays, id: \.self) { delay in
                        Text("\(delay.formatted()) s").tag(delay)
                    }
                }
                .disabled(!developer.isEnabled)
            } header: {
                Text("Content Loading")
            } footer: {
                Text("Holds every interface fetch of the content pane back by this long, cached objects included. The loading plate appears once a load takes longer than 0.1 seconds. Applies from the next object you select.")
            }

            Section {
                Toggle("Share Shared Cache Images Between Sources", isOn: $developer.sharesSharedCacheImages)
                    .disabled(!developer.isEnabled)
            } header: {
                Text("Shared Cache")
            } footer: {
                Text("My Mac keeps the data of the shared cache images a macOS process can load, My Mac (Mac Catalyst) that of the images built for Mac Catalyst alone, and every app attached on this Mac borrows both. Turned off, every source indexes and keeps its own copy, as before: for comparing memory, or for telling whether a difference comes from sharing. Windows that were borrowing start over.")
            }

            Section {
                LabeledContent("Frameworks") {
                    Text(Self.loadedSourceEditorDescription)
                        .textSelection(.enabled)
                }
            } header: {
                Text("SourceEditor")
            } footer: {
                Text("The copy of the SourceEditor frameworks this instance runs on, shown whether or not developer options are on. To compare the reconstruction with Xcode's original, run LaunchWithXcodeSourceEditorScript.sh from the repository on a Mac with System Integrity Protection off: it starts another instance on Xcode 26.6's own frameworks.")
            }
        }
    }

    private static var loadedSourceEditorDescription: String {
        switch SourceEditorFrameworks.loadedCopy {
        case .embedded:
            "The reconstruction RuntimeViewer carries"
        case .xcode(let bundleURL, let version):
            "Xcode \(version ?? "(unknown version)")'s own, from \(bundleURL.path)"
        case .other(let directory):
            directory.path
        case nil:
            "None: this build shows interfaces in the built-in text view"
        }
    }
}

#endif
