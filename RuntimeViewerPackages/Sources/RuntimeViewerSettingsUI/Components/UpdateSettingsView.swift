#if os(macOS)

import SwiftUI
import Dependencies
import RuntimeViewerSettings
import RuntimeViewerUI

struct UpdateSettingsView: View {
    @Dependency(\.updaterClient) private var updaterClient

    @AppSettings(\.update.automaticallyChecks)    private var automaticallyChecks
    @AppSettings(\.update.automaticallyDownloads) private var automaticallyDownloads
    @AppSettings(\.update.checkInterval)          private var checkInterval
    @AppSettings(\.update.includePrereleases)     private var includePrereleases

    @State private var now: Date = .now
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent("Current Version", value: updaterClient.currentVersionDisplay)
                LabeledContent("Last Check",
                               value: Self.lastCheckDisplay(updaterClient.lastCheckDate, now: now))
                if let error = updaterClient.lastCheckError {
                    LabeledContent("Last Check Error") {
                        Text(error.localizedDescription)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }
                HStack {
                    Spacer()
                    Button("Check Now") {
                        updaterClient.checkForUpdates()
                    }
                    .disabled(updaterClient.isSessionInProgress)
                }
            } header: {
                Text("Status")
            }

            Section {
                Toggle("Automatically check for updates", isOn: $automaticallyChecks)
                Picker("Check every", selection: $checkInterval) {
                    ForEach(Settings.CheckInterval.allCases, id: \.self) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .disabled(!automaticallyChecks)
            } header: {
                Text("Automatic Checks")
            }

            Section {
                Toggle("Automatically download and install updates",
                       isOn: $automaticallyDownloads)
                    .disabled(!automaticallyChecks)
            } header: {
                Text("Installation")
            }

            Section {
                Toggle("Include pre-release versions (Beta)",
                       isOn: $includePrereleases)
            } header: {
                Text("Channel")
            } footer: {
                Text("Receive release candidates and beta builds. Pre-releases may contain bugs. Changes apply to the next update check.")
            }
        }
        .onReceive(ticker) { now = $0 }
    }

    private static func lastCheckDisplay(_ date: Date?, now: Date) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

#endif
