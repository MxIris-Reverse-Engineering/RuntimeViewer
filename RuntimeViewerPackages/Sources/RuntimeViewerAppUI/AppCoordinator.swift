#if os(macOS)

import AppKit
import Dependencies
import CocoaCoordinator
import RuntimeViewerSettingsUI
import RuntimeViewerAppCore

/// `@unchecked` because `Coordinator` descends from `NSResponder`, which is not
/// `Sendable`. Every member of `Router` is `@MainActor`, and the sole instance
/// is built under `MainActor.assumeIsolated`, so nothing here is ever touched
/// off the main thread — the compiler just cannot derive that through the
/// AppKit base class.
private final class AppCoordinator: Coordinator<AppRoute, AppTransition>, @unchecked Sendable {
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

/// The live value of RuntimeViewerAppCore's `appRouter`, which declares only the interface and the
/// value tests get.
extension AppRouterKey: DependencyKey {
    package static var liveValue: any Router<AppRoute> & Sendable {
        MainActor.assumeIsolated { AppCoordinator.shared }
    }
}

#endif
