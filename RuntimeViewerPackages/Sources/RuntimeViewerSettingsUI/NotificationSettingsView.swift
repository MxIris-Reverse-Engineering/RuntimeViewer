import SwiftUI
import SettingsKit
import Dependencies
import RuntimeViewerSettings

struct NotificationSettingsView: SettingsContent {
    @AppSettings(\.notifications)
    var settings

    var body: some SettingsContent {
        SettingsGroup("Notifications", .navigation) {
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
        } icon: {
            SettingsIcon(symbol: "bell.badge", color: .clear)
        }
    }
}
