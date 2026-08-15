import AppKit
import RuntimeViewerArchitectures
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
/// Following the `AppDelegate` convention, `AppDelegate` only forwards the
/// lifecycle callbacks to the methods below.
@MainActor
final class SettingsLifecycleController {
    fileprivate static let shared = SettingsLifecycleController()

    @Dependency(\.settings) private var settings

    /// Guards against re-entering the deferred termination: AppKit asks again
    /// after `reply(toApplicationShouldTerminate:)`.
    private var isFlushingBeforeTermination = false

    private init() {}

    /// Reads the stored settings. Call first thing at launch, so the least
    /// possible amount of UI is built against default values.
    func loadOnLaunch() {
        Task { await settings.load() }
    }

    /// Backs `applicationShouldTerminate(_:)`.
    ///
    /// `applicationWillTerminate(_:)` is too late to write anything that has to
    /// be awaited — the process leaves as soon as it returns — so termination
    /// is deferred until the flush lands. The store's `save()` is a single
    /// atomic file write, and `flush()` swallows its own errors, so the reply
    /// is never left outstanding on a failure.
    ///
    /// Deferring here is only safe because `Document` can never be dirty: it
    /// overrides `updateChangeCount(_:)` to do nothing and neuters all three
    /// save actions, so there are no unsaved documents for AppKit to review.
    func shouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        guard !isFlushingBeforeTermination else { return .terminateNow }
        isFlushingBeforeTermination = true

        Task {
            await settings.flush()
            application.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { SettingsLifecycleController.shared })
    var settingsLifecycleController: SettingsLifecycleController
}
