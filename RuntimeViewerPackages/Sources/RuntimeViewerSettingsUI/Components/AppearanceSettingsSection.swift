#if !os(macOS)
import UIKit
#endif
import SwiftUI
import RuntimeViewerSettings
import UIFoundationSettingsUI

/// The appearance choice — System, Light or Dark — as a settings section.
///
/// Shared by the macOS General page and the iOS Appearance page, each after
/// its system's own: on macOS the three thumbnails of System Settings beside
/// the label; on iOS the light and dark devices of Settings › Display &
/// Brightness, with a switch in place of the System choice.
struct AppearanceSettingsSection: View {
    @AppSettings(\.general)
    var settings

    #if !os(macOS)
    @Environment(\.colorScheme)
    private var colorScheme
    #endif

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
            DeviceAppearancePicker(selection: $settings.appearance)
            Toggle("Match System", isOn: matchesSystem)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Follows the appearance chosen for the device.")
        }
        #endif
    }

    #if !os(macOS)
    /// On while the setting follows the system. Turning it off keeps the
    /// appearance on screen, as choosing a device would.
    private var matchesSystem: Binding<Bool> {
        let appearance = $settings.appearance
        let appearanceOnScreen: RuntimeViewerSettings.Settings.Appearances = colorScheme == .dark ? .dark : .light
        return Binding {
            appearance.wrappedValue == .system
        } set: { isOn in
            appearance.wrappedValue = isOn ? .system : appearanceOnScreen
        }
    }
    #endif
}

#if os(macOS)

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


#else

// MARK: - Device Appearance Picker

/// The light and the dark device of iOS Settings › Display & Brightness
/// (`DBSDeviceAppearanceTableViewCell`): equal space before, between and after
/// the two, measured from the row's edges, and twice the system spacing above
/// and below.
private struct DeviceAppearancePicker: View {
    @Binding var selection: RuntimeViewerSettings.Settings.Appearances

    @Environment(\.colorScheme)
    private var colorScheme

    var body: some View {
        // As in Settings, the check follows the appearance on screen, not the
        // setting: while the setting follows the system, the system's
        // appearance is the checked one.
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            DeviceAppearanceOptionView(
                imageName: "AppearanceLight-iOS",
                title: "Light",
                isSelected: colorScheme == .light
            ) {
                selection = .light
            }
            Spacer(minLength: 0)
            DeviceAppearanceOptionView(
                imageName: "AppearanceDark-iOS",
                title: "Dark",
                isSelected: colorScheme == .dark
            ) {
                selection = .dark
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .listRowInsets(EdgeInsets())
    }
}

// MARK: - Device Appearance Option View

/// One device, as `DBSDeviceAppearanceOptionView` draws it: the preview at
/// its own size with the lock screen time on it, the name, and the check,
/// stacked at the system spacing. Choosing the device already checked does
/// nothing.
private struct DeviceAppearanceOptionView: View {
    let imageName: String
    let title: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    @State private var feedbackCount = 0

    var body: some View {
        Button {
            guard !isSelected else { return }
            action()
            feedbackCount += 1
        } label: {
            VStack {
                Image(imageName, bundle: .module)
                    .overlay(alignment: .top) {
                        Text(verbatim: Self.lockScreenTime)
                            // Settings uses the private `.SFSoftTime-Semibold`;
                            // the rounded design is the closest public face.
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.top, 15)
                    }

                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .imageScale(.large)
                    .foregroundStyle(isSelected ? Color(uiColor: .systemBlue) : Color(uiColor: .tertiaryLabel))
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DeviceAppearanceOptionButtonStyle())
        #if os(iOS)
        // visionOS has no taps to feel, and the modifier only from visionOS 26.
        .sensoryFeedback(.impact(weight: .light), trigger: feedbackCount)
        #endif
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 9:41 in this locale's hour cycle, as Settings writes it (template `Jmm`).
    private static var lockScreenTime: String {
        let nineFortyOne = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: .now) ?? .now
        return nineFortyOne.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
    }
}

/// Settings dims a device to half while it is pressed.
private struct DeviceAppearanceOptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

#endif
