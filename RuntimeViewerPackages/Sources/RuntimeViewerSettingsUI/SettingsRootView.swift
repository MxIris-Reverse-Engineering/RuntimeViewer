import SwiftUI
import SettingsKit
import Dependencies
import Observation
import SwiftUIIntrospect

struct SettingsRootView: View {
    @Dependency(\.settings)
    private var settings

    @State
    private var viewModel = SettingsViewModel()

    var body: some View {
        SettingsView()
            .environment(settings)
            .environment(viewModel)
            .frame(minWidth: 715, maxWidth: 715)
            .frame(minHeight: 400)
            .settingsStyle(RuntimeViewerSettingsStyle())
    }
}

private struct SettingsView: SettingsContainer {
    var settingsBody: some SettingsContent {
        GeneralSettingsView()
        NotificationSettingsView()
        HelperServiceSettingsView()
    }
}
