import SwiftUI
import SwiftUIIntrospect

extension View {
    func hideSidebarToggle() -> some View {
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
