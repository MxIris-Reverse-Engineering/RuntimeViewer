#if os(macOS)

import SwiftUI
import Dependencies
import RuntimeViewerSettings
import UIFoundationSettingsUI

struct EditorSettingsView: View {
    @AppSettings(\.editor)
    var settings

    /// Resolved once per appearance of the panel. Installing Xcode while the window is open is
    /// not worth watching for, and probing on every redraw would hit the file system for no
    /// reason.
    @State private var frameworksDirectory: URL? = XcodeSourceEditorLocator.frameworksDirectory()

    private var isSourceEditorInstalled: Bool { frameworksDirectory != nil }

    var body: some View {
        SettingsForm {
            Section {
                Toggle("Use Xcode's Source Editor", isOn: $settings.usesSourceEditor)
                    .disabled(!isSourceEditorInstalled)
            } header: {
                Text("Engine")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Renders interfaces with the editor from Xcode instead of the built-in text view, adding code folding, sticky headers, a find bar, scope guides and ⌘-hover underlining. Large interfaces scroll without dropping frames.")

                    if isSourceEditorInstalled {
                        Text("Takes effect the next time content is displayed — select something in the sidebar to see the change.")
                    } else {
                        Label(
                            "Requires Xcode. No installed copy was found, so RuntimeViewer will keep using its built-in text view.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Label(
                    "Syntax coloring comes from Xcode's own tokenizer, which infers what each identifier is. The built-in text view colors from the runtime metadata instead, so it knows each identifier's real type — expect some identifiers to be colored differently, and less accurately.",
                    systemImage: "paintpalette"
                )
                .foregroundStyle(.secondary)
            } header: {
                Text("Known Limitation")
            }
        }
    }
}

#endif
