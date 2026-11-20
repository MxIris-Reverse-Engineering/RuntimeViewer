import UIKit
import Dependencies
import DependenciesMacros
import RuntimeViewerSettings

/// Reads the settings when the app launches and writes them as the app
/// leaves the foreground.
///
/// The load is synchronous because the first scene connects right after
/// `application(_:didFinishLaunchingWithOptions:)` returns and reads settings
/// as it does; a task started there could still be waiting to run.
///
/// The write follows the app, not a scene. iOS has no
/// `applicationShouldTerminate(_:)`, and a suspended app can be killed without
/// another callback, so entering the background is the last dependable moment
/// to write; `willTerminate` covers the rarer case of the system ending an app
/// that is still running. A scene's `sceneDidEnterBackground(_:)` would fire
/// while another scene is still in front.
@MainActor
final class SettingsLifecycleController {
    fileprivate static let shared = SettingsLifecycleController()

    @Dependency(\.settings) private var settings

    private var notificationObservers: [any NSObjectProtocol] = []

    private init() {}

    /// Call once, first thing at launch, before anything reads a setting.
    func loadOnLaunch() {
        settings.loadSynchronously()
        let notificationCenter = NotificationCenter.default
        for notificationName in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            let notificationObserver = notificationCenter.addObserver(forName: notificationName, object: nil, queue: .main) { [weak self] _ in
                // Delivered on the main queue, which is the main actor's.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.settings.flushSynchronously()
                }
            }
            notificationObservers.append(notificationObserver)
        }
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { SettingsLifecycleController.shared })
    var settingsLifecycleController: SettingsLifecycleController
}
