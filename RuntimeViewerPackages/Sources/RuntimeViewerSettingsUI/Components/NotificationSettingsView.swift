#if os(macOS)

import SwiftUI
import Dependencies
import RuntimeViewerSettings

struct NotificationSettingsView: View {
    @AppSettings(\.notifications)
    var settings

    var body: some View {
        SettingsForm {
            Section {
                Toggle("Enable Notifications", isOn: $settings.isEnabled)
            } footer: {
                Text("When enabled, you will receive notifications for connection events.")
            }

            Section {
                Toggle("Connection Established", isOn: $settings.showOnConnect)
                    .disabled(!settings.isEnabled)

                Toggle("Connection Lost", isOn: $settings.showOnDisconnect)
                    .disabled(!settings.isEnabled)
            } header: {
                Text("Connection Events")
            } footer: {
                Text("Choose which events trigger notifications.")
            }
        }
    }
}

#endif
