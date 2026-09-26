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
        }
    }
}

#endif
