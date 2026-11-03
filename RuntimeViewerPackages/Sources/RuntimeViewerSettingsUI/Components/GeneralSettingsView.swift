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
            Section {
                LabeledContent {
                    AppearancePicker(selection: $settings.appearance)
                } label: {
                    Text("Appearance")
                }
            }

            Section {
                Picker("Activity Style", selection: $settings.toolbarActivityStyle) {
                    ForEach(RuntimeViewerSettings.Settings.ToolbarActivityStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            } header: {
                Text("Toolbar")
            } footer: {
                Text("Xcode 26 shows the progress of background work in a capsule in the middle of the toolbar. Xcode 27 shows it in place of the window title's icon and puts the Runtime Source menu in the middle. Automatic follows the Xcode of this system: Xcode 27 from macOS 27.")
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

// MARK: - Appearance Picker

private struct AppearancePicker: View {
    @Binding var selection: RuntimeViewerSettings.Settings.Appearances

    var body: some View {
        HStack(spacing: 5) {
            AppearanceOptionView(
                mode: .system,
                imageName: "AppearanceAuto_AppearanceAuto_Normal",
                title: "System",
                isSelected: selection == .system
            ) {
                selection = .system
            }
            AppearanceOptionView(
                mode: .light,
                imageName: "AppearanceLight_AppearanceLight_Normal",
                title: "Light",
                isSelected: selection == .light
            ) {
                selection = .light
            }

            AppearanceOptionView(
                mode: .dark,
                imageName: "AppearanceDark_AppearanceDark_Normal",
                title: "Dark",
                isSelected: selection == .dark
            ) {
                selection = .dark
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Appearance Option View

private struct AppearanceOptionView: View {
    let mode: RuntimeViewerSettings.Settings.Appearances
    let imageName: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(imageName, bundle: .module)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(
                                isSelected ? Color.accentColor : Color.clear,
                                lineWidth: 3
                            )
                    )
                    .shadow(
                        color: .black.opacity(isHovering ? 0.15 : 0.1),
                        radius: isHovering ? 3 : 2,
                        x: 0,
                        y: 1
                    )

                Text(title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

#endif
