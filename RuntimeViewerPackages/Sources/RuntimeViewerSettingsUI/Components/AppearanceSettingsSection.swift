import SwiftUI
import RuntimeViewerSettings
import UIFoundationSettingsUI

/// The appearance choice — System, Light or Dark — as a settings section.
///
/// Shared by the macOS General page and the iOS Appearance page. On macOS the
/// three thumbnails sit beside the label, as in System Settings; on iOS a row
/// is too narrow for that, so the label heads the section and the thumbnails
/// fill the row.
struct AppearanceSettingsSection: View {
    @AppSettings(\.general)
    var settings

    var body: some View {
        #if os(macOS)
        Section {
            LabeledContent {
                AppearancePicker(selection: $settings.appearance)
            } label: {
                Text("Appearance")
            }
        }
        #else
        Section {
            AppearancePicker(selection: $settings.appearance)
                .frame(maxWidth: .infinity)
        } header: {
            Text("Appearance")
        }
        #endif
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
