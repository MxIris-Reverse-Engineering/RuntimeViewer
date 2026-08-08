import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerSettings
import DependenciesMacros

/// Owns what happens when the app runs out of windows and when the user brings
/// it back from the Dock.
///
/// AppKit's built-in reopen handling only creates a new untitled document when
/// it sees no visible `NSWindow` at all — and it counts every window the app
/// owns, not just document windows. With `Settings` (or any other auxiliary
/// window) still on screen it therefore does nothing, and a Dock click on an
/// app whose document windows are all closed appears to be ignored. This
/// controller decides on document windows alone, which is the window kind the
/// Dock icon stands for here.
///
/// Following the `AppDelegate` convention, `AppDelegate` only forwards the two
/// delegate callbacks to the methods below.
@MainActor
final class WindowLifecycleController {
    fileprivate static let shared = WindowLifecycleController()

    @Dependency(\.settings) private var settings

    private init() {}

    /// Backs `applicationShouldTerminateAfterLastWindowClosed(_:)`.
    var shouldTerminateAfterLastWindowClosed: Bool {
        settings.general.terminatesAfterLastWindowClosed
    }

    /// Backs `applicationShouldHandleReopen(_:hasVisibleWindows:)`.
    ///
    /// - Returns: `false` once it has handled the reopen itself, `true` to let
    ///   AppKit run its default behaviour.
    func handleReopen(for application: NSApplication) -> Bool {
        // A hidden app (⌘H) orders all of its windows out, so the checks below
        // cannot tell "hidden" from "closed". Unhiding is what the user wants
        // here, and AppKit already does it.
        guard !application.isHidden else { return true }

        let documentWindows = NSDocumentController.shared.documents
            .flatMap(\.windowControllers)
            .compactMap(\.window)

        // Something is already on screen — let AppKit order it front.
        if documentWindows.contains(where: \.isVisible) { return true }

        // A minimized window still means "this document is open"; restore it
        // rather than piling a second window on top of it.
        if let miniaturizedWindow = documentWindows.first(where: \.isMiniaturized) {
            miniaturizedWindow.deminiaturize(nil)
            return false
        }

        // A document that outlived its window (ordered out but not closed):
        // bring it back instead of creating a duplicate.
        if let orderedOutWindow = documentWindows.first {
            orderedOutWindow.makeKeyAndOrderFront(nil)
            return false
        }

        do {
            try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        } catch {
            application.presentError(error)
        }
        return false
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { WindowLifecycleController.shared })
    var windowLifecycleController: WindowLifecycleController
}
