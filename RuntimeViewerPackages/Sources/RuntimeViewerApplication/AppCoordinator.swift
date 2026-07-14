#if os(macOS)

import AppKit
import Dependencies
import DependenciesMacros
import CocoaCoordinator
import RuntimeViewerSettingsUI

public enum AppRoute: Routable {
    case settings
}

private final class AppCoordinator: Coordinator<AppRoute, AppTransition> {
    static let shared = AppCoordinator(initialRoute: nil)

    @Dependency(\.settingsWindowController)
    var settingsWindowController
    
    override func prepareTransition(for route: AppRoute) -> AppTransition {
        switch route {
        case .settings:
            settingsWindowController.showWindow(nil)
            return .none()
        }
    }
}

@MainActor
extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { AppCoordinator.shared })
    public var appRouter: any Router<AppRoute>
}


#endif
