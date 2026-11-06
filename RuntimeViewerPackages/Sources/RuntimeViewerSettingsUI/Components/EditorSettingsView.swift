#if os(macOS)

import SwiftUI
import RuntimeViewerSettings
import UIFoundationSettingsUI

struct EditorSettingsView: View {
    @AppSettings(\.editor)
    var settings

    /// Which editor this build shows interfaces in. Not a choice: a build that carries the
    /// reconstructed frameworks uses SourceEditor, any other build the built-in text view.
    private let availability = SourceEditorFrameworks.availability

    private var isSourceEditorAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    var body: some View {
        SettingsForm {
            Section {
                switch availability {
                case .available:
                    Label(
                        "Interfaces are shown in SourceEditor, a rebuild of Xcode's source editor that comes with RuntimeViewer: code folding, sticky headers, a minimap, scope guides and ⌘-hover underlining. Large interfaces scroll without dropping frames.",
                        systemImage: "checkmark.circle"
                    )
                case .notEmbedded:
                    Label(
                        "This build of RuntimeViewer does not include SourceEditor, so interfaces are shown in the built-in text view. The official releases include it.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.secondary)
                case .unsupportedArchitecture:
                    Label(
                        "SourceEditor needs a Mac with Apple silicon, so interfaces are shown in the built-in text view.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Engine")
            }

            Section {
                Toggle("Line Numbers", isOn: $settings.showsLineNumbers)
                Toggle("Code Folding Ribbon", isOn: $settings.showsFoldingRibbon)
                Toggle("Sticky Headers", isOn: $settings.showsStickyHeaders)
                Toggle("Minimap", isOn: $settings.showsMinimap)
                Toggle("Scope Guides", isOn: $settings.showsScopeGuides)
                Toggle("Invisibles", isOn: $settings.showsInvisibles)
                Toggle("Mark Separators", isOn: $settings.showsMarkSeparators)
                Toggle("Comment Tags", isOn: $settings.showsCommentTags)
                Toggle("Insertion Point", isOn: $settings.showsInsertionPoint)
            } header: {
                Text("Display")
            } footer: {
                Text("Changes apply immediately. Sticky headers pin the enclosing declarations to the top of the view while scrolling; the folding ribbon draws the arrows that collapse a declaration. Mark separators draw a rule at every MARK comment, and have nothing to draw until generated interfaces contain them. Comment tags draw generated comments — addresses, offsets, layouts — as tags, and let field layouts and enum case layouts collapse; copying and finding still use the comments as printed. Insertion point draws the blinking caret where a click leaves it; interfaces cannot be edited, so it is off by default.")
            }
            .disabled(!isSourceEditorAvailable)

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
