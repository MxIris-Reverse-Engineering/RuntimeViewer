import SwiftUI
import Dependencies
import SwiftUIIntrospect

struct SettingsRootView: View {
    @Dependency(\.settings)
    private var settings

    var body: some View {
        SettingsNavigationView()
            .environment(settings)
            .frame(minWidth: 715, maxWidth: 715)
            .frame(minHeight: 400)
    }
}

// MARK: - Settings Page

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case notifications = "Notifications"
    case transformer = "Transformer"
    case backgroundIndexing = "Background Indexing"
    case mcp = "MCP"
    case updates = "Updates"
    case helper = "Helper"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell.badge"
        case .transformer: "arrow.triangle.2.circlepath"
        case .backgroundIndexing: "square.stack.3d.down.right"
        case .mcp: "network"
        case .updates: "arrow.down.circle"
        case .helper: "wrench.and.screwdriver"
        }
    }

    @ViewBuilder
    var contentView: some View {
        switch self {
        case .general: GeneralSettingsView()
        case .notifications: NotificationSettingsView()
        case .transformer: TransformerSettingsView()
        case .backgroundIndexing: BackgroundIndexingSettingsView()
        case .mcp: MCPSettingsView()
        case .updates: UpdateSettingsView()
        case .helper: HelperServiceSettingsView()
        }
    }
}

// MARK: - Settings Navigation View

private struct SettingsNavigationView: View {
    @State private var selectedPage: SettingsPage? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $selectedPage) { page in
                Label {
                    Text(page.rawValue)
                } icon: {
                    SettingsIcon(symbol: page.systemImage, color: .clear)
                }
                .tag(page)
            }
            .navigationSplitViewColumnWidth(185)
        } detail: {
            if let selectedPage {
                selectedPage.contentView
                    .navigationTitle(selectedPage.rawValue)
            }
        }
        .hideSidebarToggle()
    }
}
