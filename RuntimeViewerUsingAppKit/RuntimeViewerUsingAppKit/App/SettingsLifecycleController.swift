import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerSettings
import DependenciesMacros

/// Owns reading the user's settings at launch and writing them back before the
/// process exits.
///
/// Both ends used to be implicit. The read happened as a side effect of
/// whichever service first resolved `\.settings`, and there was no write at
/// all — the store's one-second auto-save debounce simply lost anything
/// changed just before quitting.
///
/// It also carries the one setting the engine manager takes, whether the
/// engines share the shared cache images, from the stored settings into the
/// manager.
///
/// Following the `AppDelegate` convention, `AppDelegate` only forwards the
/// lifecycle callbacks to the methods below.
@MainActor
final class SettingsLifecycleController {
    fileprivate static let shared = SettingsLifecycleController()

    @Dependency(\.settings) private var settings

    @Dependency(\.runtimeEngineManagerSettingsFollower) private var runtimeEngineManagerSettingsFollower

    private init() {}

    /// Reads the stored settings. Call first thing at launch, so the least
    /// possible amount of UI is built against default values. Once they are
    /// read, the engine manager follows the ones it takes — started only
    /// then: `load()` replaces the object a tracking started earlier would
    /// have followed.
    func loadOnLaunch() {
        Task {
            await settings.load()
            runtimeEngineManagerSettingsFollower.startFollowing()
        }
    }

    /// Backs `applicationShouldTerminate(_:)`.
    ///
    /// The flush is synchronous on purpose. The previous shape — return
    /// `.terminateLater` and reply from a main-actor task after an async
    /// flush — deadlocked whenever `terminate(_:)` was invoked from a
    /// main-queue block, which is how the helper-reinstall relaunch quits:
    /// AppKit waits for the reply by spinning a nested run loop, the main
    /// queue's drain is not reentrant, so the task that would deliver the
    /// reply never ran and the app could only be force-quit. The store's
    /// save is a single atomic file write, cheap enough to block on, and
    /// `flushSynchronously()` swallows its own errors, so termination is
    /// never held up by a failed write.
    func shouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        settings.flushSynchronously()
        return .terminateNow
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { SettingsLifecycleController.shared })
    var settingsLifecycleController: SettingsLifecycleController
}
