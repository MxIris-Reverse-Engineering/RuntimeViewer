import SwiftUI
import SettingsKit
import Dependencies
import RuntimeViewerSettings

struct RuntimeViewerSettingsStyle: SettingsStyle {
    init() {}

    func makeContainer(configuration: ContainerConfiguration) -> some View {
        SidebarContainer(configuration: configuration)
    }

    func makeGroup(configuration: GroupConfiguration) -> some View {
        switch configuration.presentation {
        case .navigation:
            SidebarNavigationLink(configuration: configuration)
        case .inline:
            Section {
                configuration.content
            } footer: {
                if let footer = configuration.footer {
                    Text(footer)
                }
            }
        }
    }

    func makeItem(configuration: ItemConfiguration) -> some View {
        configuration.content
    }

    private struct SidebarNavigationLink: View {
        let configuration: SettingsGroupConfiguration
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        var body: some View {
            destinationBasedLink
        }

        private var destinationBasedLink: some View {
            NavigationLink {
                NavigationStack {
//                    List {
                    configuration.content
//                    }
                        .navigationTitle(configuration.title)
                }
            } label: {
                configuration.label
            }
        }

        private var selectionBasedLink: some View {
            NavigationLink(value: configuration) {
                configuration.label
            }
        }
    }

    private struct SidebarContainer: View {
        let configuration: SettingsContainerConfiguration

        @State
        private var selectedGroup: SettingsGroupConfiguration?

        var body: some View {
            NavigationSplitView {
                List(selection: selectionBinding) {
                    configuration.content
                }
                .navigationTitle(configuration.title)
                .navigationSplitViewColumnWidth(185)

            } detail: {
                Text("Select a setting")
                    .foregroundStyle(.secondary)
            }
            .hideSidebarToggle()
        }

        private var selectionBinding: Binding<SettingsGroupConfiguration?>? { nil }
    }
}

import SwiftUIIntrospect

extension View {
    fileprivate func hideSidebarToggle() -> some View {
        modifier(HideSidebarToggleViewModifier())
    }
}

private struct HideSidebarToggleViewModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .introspect(.window, on: .macOS(.v13, .v14, .v15, .v26)) { window in
                if let toolbar = window.toolbar {
                    let sidebarItem = "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
                    let sidebarToggle = toolbar.items.first(where: { $0.itemIdentifier.rawValue == sidebarItem })
                    sidebarToggle?.view?.isHidden = true
                }
            }
    }
}
