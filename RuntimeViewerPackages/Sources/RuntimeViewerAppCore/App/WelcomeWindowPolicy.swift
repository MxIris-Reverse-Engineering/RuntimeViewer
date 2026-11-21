#if os(macOS)

/// When the macOS app shows its Welcome window instead of opening a window on My Mac.
///
/// AppKit asks whether to open an untitled document while it handles the open-application event,
/// which can come before the app has read its settings: `applicationDidFinishLaunching` starts that
/// read, and the event that restores windows lands before it. So a request that comes too early is
/// held, and decided once the settings are read — by then a document window may already be up, and
/// neither window is wanted. Settings › General › Show Welcome Window at Launch
/// (`Settings.General.showsWelcomeWindowAtLaunch`) decides between the two windows, at launch and
/// when the Dock icon is clicked with no document window to bring back.
///
/// The app's `WelcomeController` carries the decisions out; this type only makes them, so that a
/// test can.
public enum WelcomeWindowPolicy {
    public enum Decision: Equatable, Sendable {
        /// Show the Welcome window and open no document.
        case showWelcomeWindow
        /// Open a new window on My Mac, as the app did before it had a Welcome window.
        case openUntitledDocument
        /// The settings are not read yet: hold the request and decide once they are.
        case waitForSettings
    }

    /// AppKit asks whether to open an untitled document: at launch, when no window was restored and
    /// no file was opened.
    public static func decisionForUntitledDocumentRequest(
        areSettingsLoaded: Bool,
        showsWelcomeWindow: Bool
    ) -> Decision {
        guard areSettingsLoaded else { return .waitForSettings }
        return showsWelcomeWindow ? .showWelcomeWindow : .openUntitledDocument
    }

    /// A request held until the settings were read. `nil` when a document window came up in the
    /// meantime, so that neither window is wanted.
    public static func decisionAfterSettingsLoaded(
        showsWelcomeWindow: Bool,
        hasDocumentWindow: Bool
    ) -> Decision? {
        guard !hasDocumentWindow else { return nil }
        return showsWelcomeWindow ? .showWelcomeWindow : .openUntitledDocument
    }

    /// The Dock icon was clicked with no document window to bring back.
    public static func decisionForReopen(showsWelcomeWindow: Bool) -> Decision {
        showsWelcomeWindow ? .showWelcomeWindow : .openUntitledDocument
    }
}

#endif
