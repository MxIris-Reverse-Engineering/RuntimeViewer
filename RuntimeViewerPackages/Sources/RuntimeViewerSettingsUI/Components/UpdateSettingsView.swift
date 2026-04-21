#if os(macOS)

import SwiftUI
import Dependencies
import RuntimeViewerSettings
import RuntimeViewerUI

struct UpdateSettingsView: View {
    @AppSettings(\.update.automaticallyChecks)    private var automaticallyChecks
    @AppSettings(\.update.automaticallyDownloads) private var automaticallyDownloads
    @AppSettings(\.update.checkInterval)          private var checkInterval
    @AppSettings(\.update.includePrereleases)     private var includePrereleases

    @State private var now: Date = .now
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent("Current Version",
                               value: UpdateStatusReader.currentVersionDisplay())
                LabeledContent("Last Check",
                               value: UpdateStatusReader.lastCheckDisplay(now: now))
                HStack {
                    Spacer()
                    Button("Check Now") {
                        UpdateStatusReader.triggerCheck()
                    }
                    .disabled(UpdateStatusReader.isSessionInProgress())
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
}

/// Module boundary: this type is overridden at the app layer to talk to
/// `UpdaterService`. In the settings package, it provides safe defaults so
/// the view compiles and previews.
public enum UpdateStatusReader {
    public static var currentVersionDisplayProvider: () -> String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    public static var lastCheckDateProvider: () -> Date? = { nil }

    public static var isSessionInProgressProvider: () -> Bool = { false }

    public static var triggerCheckAction: () -> Void = {}

    static func currentVersionDisplay() -> String { currentVersionDisplayProvider() }

    static func lastCheckDisplay(now: Date) -> String {
        guard let date = lastCheckDateProvider() else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func isSessionInProgress() -> Bool { isSessionInProgressProvider() }
    static func triggerCheck() { triggerCheckAction() }
}

#endif
