#if os(macOS)

import AppKit
import Dependencies
import DependenciesMacros

/// Starts a second instance of the app and quits this one.
///
/// Lives beside the settings schema rather than in the app target because both sides need it:
/// the helper-service version check reinstalls a helper and asks the user to restart, and the
/// Editor pane changes which Xcode the source editor loads from — a choice a running process
/// cannot act on, since the frameworks are `dlopen`ed once and never unloaded.
///
/// One implementation, not two: the same sequence written twice drifts, and the ordering below
/// is not obvious enough to re-derive.
@MainActor
public final class ApplicationRelauncher {
    fileprivate static let shared = ApplicationRelauncher()

    private init() {}

    /// Launches the replacement *first* and only terminates once it is on its way, so a failure
    /// to launch leaves the user with the app they had rather than with nothing.
    ///
    /// `createsNewApplicationInstance` is what keeps this from being a no-op: without it
    /// LaunchServices activates the instance that is already running — this one — and the
    /// terminate below then closes the only copy there is.
    ///
    /// The terminate is dispatched rather than called inline because the completion handler runs
    /// off the main thread. It reaches `applicationShouldTerminate`, which replies `.terminateNow`
    /// after a synchronous settings flush; see `SettingsLifecycleController` for why replying
    /// `.terminateLater` from a main-queue block deadlocks instead.
    public func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { ApplicationRelauncher.shared })
    public var applicationRelauncher: ApplicationRelauncher
}

#endif
