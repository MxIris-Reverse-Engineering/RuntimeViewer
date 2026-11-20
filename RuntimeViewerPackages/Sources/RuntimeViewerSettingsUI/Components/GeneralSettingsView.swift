#if os(macOS)

import SwiftUI
import Dependencies
import RuntimeViewerSettings
import UIFoundationSettingsUI

struct GeneralSettingsView: View {
    @AppSettings(\.general)
    var settings

    var body: some View {
        SettingsForm {
            AppearanceSettingsSection()

            Section {
                Picker("Activity Style", selection: $settings.toolbarActivityStyle) {
                    ForEach(RuntimeViewerSettings.Settings.ToolbarActivityStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            } header: {
                Text("Toolbar")
            } footer: {
                Text("Xcode 26 shows the progress of background work in a capsule in the middle of the toolbar, with the runtime source picker at its leading edge. Xcode 27 shows it in place of the window title's icon and puts the runtime source picker in the middle. Classic is the toolbar from before both: no progress in it, and the runtime source as a pop-up menu. Automatic follows the Xcode of this system: Xcode 27 from macOS 27.")
            }

            Section {
                Toggle("Quit After Closing Last Window", isOn: $settings.terminatesAfterLastWindowClosed)
            } header: {
                Text("Windows")
            } footer: {
                Text("When off, the app keeps running with no window open and clicking its Dock icon opens a new window. When on, closing the last window quits the app.")
            }

            Section {
                LabeledContent("Sidebar Max Expansion Depth") {
                    Stepper(
                        "",
                        value: $settings.sidebarMaxExpansionDepth.asDouble,
                        in: 1...20,
                        step: 1,
                        format: .number.precision(.fractionLength(0))
                    )
                    .labelsHidden()
                }
            } header: {
                Text("Sidebar")
            } footer: {
                Text("Limits how deep a double-click recursively expands a node in the sidebar. Higher values expand more, but may briefly freeze the main thread on very large subtrees (e.g. the dyld shared cache root).")
            }
        }
    }
}

extension Binding where Value: BinaryInteger {
    var asDouble: Binding<Double> {
        Binding<Double>(
            get: { Double(self.wrappedValue) },
            set: { self.wrappedValue = Value($0.rounded()) }
        )
    }
}

#endif
