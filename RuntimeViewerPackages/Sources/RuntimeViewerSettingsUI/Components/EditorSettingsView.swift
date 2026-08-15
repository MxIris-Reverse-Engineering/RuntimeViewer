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
                    Text("Renders interfaces with the editor from Xcode instead of the built-in text view, adding code folding, sticky headers, a minimap, scope guides and ⌘-hover underlining. Large interfaces scroll without dropping frames.")

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
                Toggle("Line Numbers", isOn: $settings.showsLineNumbers)
                Toggle("Code Folding Ribbon", isOn: $settings.showsFoldingRibbon)
                Toggle("Sticky Headers", isOn: $settings.showsStickyHeaders)
                Toggle("Minimap", isOn: $settings.showsMinimap)
                Toggle("Scope Guides", isOn: $settings.showsScopeGuides)
                Toggle("Invisibles", isOn: $settings.showsInvisibles)
                Toggle("Mark Separators", isOn: $settings.showsMarkSeparators)
            } header: {
                Text("Display")
            } footer: {
                Text("Changes apply immediately. Sticky headers pin the enclosing declarations to the top of the view while scrolling; the folding ribbon draws the arrows that collapse a declaration. Mark separators draw a rule at every MARK comment, and have nothing to draw until generated interfaces contain them.")
            }
            .disabled(!isSourceEditorInstalled || !settings.usesSourceEditor)

            Section {
                Label(
                    "Syntax coloring uses the runtime metadata the interface was generated from, not Xcode's own tokenizer — the same information the built-in text view colors from. The exception is a token the editor parses as spanning two of those runs, such as a parameter type and the parameter name after it, which keeps the editor's own reading.",
                    systemImage: "paintpalette"
                )
                .foregroundStyle(.secondary)
            } header: {
                Text("Syntax Coloring")
            }
        }
    }
}

#endif
