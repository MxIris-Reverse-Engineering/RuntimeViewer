import AppKit
import FoundationToolbox
import OSLog
import RuntimeViewerApplication
import RuntimeViewerSettings
import Dependencies
import DependenciesMacros

/// Shows the onboarding pages: the welcome page on someone's first launch, What's New on the first
/// launch of a new feature release, and What's New again from Help › What's New in RuntimeViewer
/// (proposal `onboarding-pages`).
///
/// RuntimeViewerAppCore's `OnboardingPolicy` decides which page a launch shows, once the settings are
/// read; RuntimeViewerAppUI draws it with OnBoardingKit. On a document window the page is a sheet. The
/// Welcome window is borderless and never becomes main, and a sheet would hang off its bare top edge, so
/// while it is the window in front the page shows in a window of its own in front of it. At launch the
/// page waits for the first of the two to come up.
///
/// Continue records the page's release (`AppDefaults.lastPresentedOnboardingRelease`), so the page shows
/// once; quitting with the page still up shows it again on the next launch. The Help menu's page records
/// nothing.
///
/// Following the `AppDelegate` convention, `AppDelegate` only forwards to the methods below.
@Loggable
@MainActor
final class OnboardingController {
    fileprivate static let shared = OnboardingController()

    @Dependency(\.appDefaults) private var appDefaults
    @Dependency(\.settings) private var settings
    @Dependency(\.settingsLifecycleController) private var settingsLifecycleController
    @Dependency(\.welcomeController) private var welcomeController

    private let catalog = OnboardingCatalog.runtimeViewer

    /// The launch's page, while it waits for a window to show on.
    private var pendingLaunchPage: OnboardingPage?

    private var windowObservations: [any NSObjectProtocol] = []

    /// The page on screen. The sheet or the window showing it keeps it alive.
    private weak var presentedContainer: NSViewController?

    /// The window of a page shown in a window of its own, kept until the next one replaces it.
    private var standaloneWindow: NSWindow?

    private init() {}

    /// The feature release of the running app, from its marketing version.
    private var currentRelease: FeatureRelease? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(FeatureRelease.init(marketingVersion:))
    }

    // MARK: - Lifecycle

    /// Called from `applicationDidFinishLaunching(_:)`, after `WelcomeController.start()`.
    func start() {
        Task { [weak self] in
            guard let self else { return }
            await settingsLifecycleController.waitUntilLoaded()
            decideLaunchPage()
        }
    }

    /// Help › What's New in RuntimeViewer: the running release's page, or the latest one before it. On
    /// the main window when it is a document window, in a window of its own otherwise.
    func showWhatsNew() {
        guard let currentRelease, let page = catalog.latestWhatsNewPage(upTo: currentRelease) else {
            #log(.info, "No What's New page up to the running release")
            return
        }
        let documentWindow = NSApp.mainWindow.flatMap { isDocumentWindow($0) ? $0 : nil }
        present(page, onSheetOf: documentWindow, recording: nil)
    }

    // MARK: - Launch

    private func decideLaunchPage() {
        guard let currentRelease else {
            #log(.error, "The marketing version names no feature release; no onboarding page")
            return
        }
        guard let page = OnboardingPolicy.pageForLaunch(
            currentRelease: currentRelease,
            lastPresentedRelease: appDefaults.lastPresentedOnboardingRelease,
            hasStoredSettings: settings.didFindStoredSettingsOnLoad,
            catalog: catalog
        ) else { return }

        if let mainWindow = NSApp.mainWindow, isDocumentWindow(mainWindow) {
            present(page, onSheetOf: mainWindow, recording: currentRelease)
        } else if welcomeController.isShowingWindow {
            present(page, onSheetOf: nil, recording: currentRelease)
        } else {
            waitForWindow(toPresent: page, recording: currentRelease)
        }
    }

    /// Shows the page once a document window becomes main or the Welcome window becomes key, whichever
    /// comes first.
    private func waitForWindow(toPresent page: OnboardingPage, recording release: FeatureRelease) {
        pendingLaunchPage = page
        for notificationName in [NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification] {
            let observation = NotificationCenter.default.addObserver(forName: notificationName, object: nil, queue: .main) { [weak self] notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.presentPendingLaunchPage(onWindowCameForward: window, recording: release)
                }
            }
            windowObservations.append(observation)
        }
    }

    private func presentPendingLaunchPage(onWindowCameForward window: NSWindow, recording release: FeatureRelease) {
        guard let page = pendingLaunchPage else { return }
        let documentWindow: NSWindow?
        if isDocumentWindow(window), window.isMainWindow {
            documentWindow = window
        } else if welcomeController.owns(window) {
            documentWindow = nil
        } else {
            return
        }
        pendingLaunchPage = nil
        windowObservations.forEach(NotificationCenter.default.removeObserver(_:))
        windowObservations.removeAll()
        present(page, onSheetOf: documentWindow, recording: release)
    }

    // MARK: - Presenting

    private func isDocumentWindow(_ window: NSWindow) -> Bool {
        window.windowController?.document != nil
    }

    /// Shows the page as a sheet of `documentWindow`, or in a window of its own when that is `nil` or
    /// already has a sheet. Does nothing while a page is on screen.
    ///
    /// - Parameter release: What Continue records, or `nil` to record nothing.
    private func present(_ page: OnboardingPage, onSheetOf documentWindow: NSWindow?, recording release: FeatureRelease?) {
        guard presentedContainer?.viewIfLoaded?.window?.isVisible != true else { return }
        guard let container = page.makeTemplateContainerViewController(onContinue: { [weak self] in
            guard let self, let release else { return }
            appDefaults.lastPresentedOnboardingRelease = release
        }) else {
            #log(.info, "OnBoardingKit is not on this system; no onboarding page")
            return
        }
        presentedContainer = container

        if let documentWindow, documentWindow.attachedSheet == nil, let contentViewController = documentWindow.contentViewController {
            contentViewController.presentAsSheet(container)
        } else {
            // No close button, as a sheet has none: Continue (Return) is the one way out, and it records
            // the release, so a page closed any other way would come back on the next launch.
            let window = NSWindow(contentViewController: container)
            window.styleMask = [.titled, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            standaloneWindow = window
        }
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { OnboardingController.shared })
    var onboardingController: OnboardingController
}
