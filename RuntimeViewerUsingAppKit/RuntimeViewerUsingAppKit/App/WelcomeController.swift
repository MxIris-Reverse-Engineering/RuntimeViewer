import AppKit
import SFSymbols
import UIFoundation
import RuntimeViewerApplication
import RuntimeViewerSettings
import Dependencies
import DependenciesMacros

/// Owns the Welcome window: UIFoundation's `WelcomePanelController` in its Xcode 26 style, with the
/// recently opened files on its right and two actions on its left, and when it shows instead of a
/// new window on My Mac.
///
/// It shows at launch when AppKit would open an untitled document — no window restored, no file
/// opened — and when the Dock icon is clicked with no document window to bring back, as long as
/// Settings › General › Show Welcome Window at Launch is on. `WelcomeWindowPolicy`
/// (RuntimeViewerAppCore) makes those decisions; this controller carries them out.
///
/// AppKit asks about the untitled document while it handles the open-application event, which can
/// come before `SettingsLifecycleController` has read the settings. A request that comes too early is
/// held and decided in `start()`, once they are read — by then a document window may be up, and then
/// neither window opens.
///
/// The panel closes as soon as a document window becomes main, never when a document is merely added:
/// its window is not on screen yet then, and with Quit After Closing Last Window on, closing the only
/// window would quit the app.
///
/// Following the `AppDelegate` convention, `AppDelegate` only forwards to the methods below.
@MainActor
final class WelcomeController: NSObject {
    fileprivate static let shared = WelcomeController()

    @Dependency(\.settings) private var settings
    @Dependency(\.settingsLifecycleController) private var settingsLifecycleController

    /// AppKit asked for an untitled document before the settings were read.
    private var hasPendingLaunchRequest = false

    private var mainWindowObservation: (any NSObjectProtocol)?

    /// Made the first time it shows, and kept: the panel pulls its list again every time it shows.
    private var welcomePanel: WelcomePanelController?

    private override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// Backs `applicationShouldOpenUntitledFile(_:)`.
    ///
    /// - Returns: `true` to let AppKit open a new window on My Mac.
    func shouldOpenUntitledDocument() -> Bool {
        let decision = WelcomeWindowPolicy.decisionForUntitledDocumentRequest(
            areSettingsLoaded: settingsLifecycleController.isLoaded,
            showsWelcomeWindow: settings.general.showsWelcomeWindowAtLaunch
        )
        switch decision {
        case .showWelcomeWindow:
            showWindow()
            return false
        case .openUntitledDocument:
            return true
        case .waitForSettings:
            hasPendingLaunchRequest = true
            return false
        }
    }

    /// Called from `applicationDidFinishLaunching(_:)`, after `SettingsLifecycleController.loadOnLaunch()`.
    func start() {
        mainWindowObservation = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] notification in
            let isDocumentWindow = (notification.object as? NSWindow)?.windowController?.document != nil
            MainActor.assumeIsolated {
                guard let self, isDocumentWindow else { return }
                self.welcomePanel?.close()
            }
        }

        Task { [weak self] in
            guard let self else { return }
            await settingsLifecycleController.waitUntilLoaded()
            decidePendingLaunchRequest()
        }
    }

    // MARK: - Showing

    /// Window › Welcome to RuntimeViewer.
    func showWindow() {
        let welcomePanel = welcomePanel ?? makeWelcomePanel()
        self.welcomePanel = welcomePanel
        welcomePanel.showWindow(nil)
    }

    /// `WindowLifecycleController`'s last resort when the Dock icon is clicked with no document
    /// window to bring back.
    func showInsteadOfUntitledDocument() {
        switch WelcomeWindowPolicy.decisionForReopen(showsWelcomeWindow: settings.general.showsWelcomeWindowAtLaunch) {
        case .showWelcomeWindow:
            showWindow()
        case .openUntitledDocument, .waitForSettings:
            openUntitledDocument()
        }
    }

    private func decidePendingLaunchRequest() {
        guard hasPendingLaunchRequest else { return }
        hasPendingLaunchRequest = false

        let decision = WelcomeWindowPolicy.decisionAfterSettingsLoaded(
            showsWelcomeWindow: settings.general.showsWelcomeWindowAtLaunch,
            hasDocumentWindow: !NSDocumentController.shared.documentWindows.isEmpty
        )
        switch decision {
        case .showWelcomeWindow:
            showWindow()
        case .openUntitledDocument:
            openUntitledDocument()
        case .waitForSettings, nil:
            break
        }
    }

    private func openUntitledDocument() {
        do {
            try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        } catch {
            NSApplication.shared.presentError(error)
        }
    }

    private func makeWelcomePanel() -> WelcomePanelController {
        var configuration = WelcomePanelController.Configuration(style: .xcode26)
        // The panel would take `CFBundleName`, which a Debug build sets to its product name
        // (RuntimeViewer-Debug-arm64e); the display name is RuntimeViewer in every configuration.
        configuration.welcomeLabelText = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        // The list holds the files opened in file mode — documents are never saved — so it lists
        // files, not projects.
        configuration.projectListPlaceholderText = "No Recent Files"
        // The style's own glow is Xcode's, tinted the blue of Xcode's icon; behind this app's dark
        // icon it reads as a stray blue haze. Same size and offset in white, about as bright as Xcode's:
        // the panel draws it in a dark appearance only, where a black shadow does not show at all.
        let appIconShadow = NSShadow()
        appIconShadow.shadowColor = NSColor.white.withAlphaComponent(0.2)
        appIconShadow.shadowBlurRadius = 50
        appIconShadow.shadowOffset = NSSize(width: 0, height: 2)
        configuration.appIconImageShadow = appIconShadow
        configuration.primaryAction = .init(
            image: SFSymbols(systemName: .plusSquare).nsImage,
            title: "New Window on My Mac",
            action: { _ in
                MainActor.assumeIsolated {
                    NSDocumentController.shared.newDocument(nil)
                }
            }
        )
        configuration.secondaryAction = .init(
            image: SFSymbols(systemName: .folder).nsImage,
            title: "Open File…",
            action: { _ in
                MainActor.assumeIsolated {
                    NSDocumentController.shared.openDocument(nil)
                }
            }
        )

        let welcomePanel = WelcomePanelController(configuration: configuration)
        welcomePanel.dataSource = self
        welcomePanel.delegate = self
        return welcomePanel
    }
}

// MARK: - WelcomePanelController.DataSource

extension WelcomeController: @preconcurrency WelcomePanelController.DataSource {
    /// Open Recent's list: the files read in file mode, which `FileController` records once read.
    func welcomePanelUsesRecentDocumentURLs(_ welcomePanel: WelcomePanelController) -> Bool {
        true
    }

    // Never called while the recent-documents path is on.
    func numberOfProjects(in welcomePanel: WelcomePanelController) -> Int {
        0
    }

    func welcomePanel(_ welcomePanel: WelcomePanelController, urlForProjectAtIndex index: Int) -> URL {
        NSDocumentController.shared.recentDocumentURLs[index]
    }
}

// MARK: - WelcomePanelController.Delegate

extension WelcomeController: @preconcurrency WelcomePanelController.Delegate {
    // Only the Xcode 14 style has the checkbox; the setting lives in Settings › General.
    func welcomePanel(_ welcomePanel: WelcomePanelController, didCheckShowPanelWhenLaunch isCheck: Bool) {}

    func welcomePanel(_ welcomePanel: WelcomePanelController, didSelectProjectAtIndex index: Int) {}

    /// Opens the file as Open Recent does: `DocumentController` hands it to `FileController`, which
    /// reports a file it cannot read. A double click on empty space reports -1.
    func welcomePanel(_ welcomePanel: WelcomePanelController, didDoubleClickProjectAtIndex index: Int) {
        let recentDocumentURLs = NSDocumentController.shared.recentDocumentURLs
        guard recentDocumentURLs.indices.contains(index) else { return }
        NSDocumentController.shared.openDocument(withContentsOf: recentDocumentURLs[index], display: true) { _, _, _ in }
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { WelcomeController.shared })
    var welcomeController: WelcomeController
}
