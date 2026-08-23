#if os(macOS)

import AppKit
import Dependencies
import DependenciesMacros
import CocoaCoordinator
import RuntimeViewerSettingsUI

public enum AppRoute: Routable {
    case settings
}

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

@MainActor
extension DependencyValues {
    // `& Sendable` is load-bearing: `Router` is `@MainActor`, but an existential
    // does not pick up `Sendable` from that, and a dependency value has to be
    // `Sendable` to cross into `DependencyValues`.
    @DependencyEntry(liveValue: MainActor.assumeIsolated { AppCoordinator.shared })
    public var appRouter: any Router<AppRoute> & Sendable
}


#endif
