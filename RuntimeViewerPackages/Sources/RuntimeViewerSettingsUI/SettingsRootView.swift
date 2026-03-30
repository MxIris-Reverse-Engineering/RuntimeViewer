import SwiftUI
import SettingsKit
import Dependencies
import SwiftUIIntrospect

struct SettingsRootView: View {
    @Dependency(\.settings)
    private var settings

    var body: some View {
        SettingsView()
            .environment(settings)
            .frame(minWidth: 715, maxWidth: 715)
            .frame(minHeight: 400)
            .settingsStyle(RuntimeViewerSettingsStyle())
    }
}

private struct SettingsView: SettingsContainer {
    var settingsBody: some SettingsContent {
        GeneralSettingsView()
        NotificationSettingsView()
        TransformerSettingsView()
        MCPSettingsView()
        HelperServiceSettingsView()
    }
}
