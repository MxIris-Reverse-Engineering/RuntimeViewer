import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerCommunication
import RuntimeViewerMCPBridge
import RuntimeViewerSimulatorInstaller

/// The app's entry point.
///
/// Hand-written because there is no `MainMenu.xib` any more, and `@main` on an
/// `NSApplicationDelegate` only synthesizes a call to `NSApplicationMain` —
/// which instantiates and connects the delegate solely through the principal
/// nib. Without one, nothing would ever create `AppDelegate` and no lifecycle
/// callback would fire. So the three things the nib did — create the delegate,
/// connect it, install the main menu — are done here instead.
@main
@MainActor
enum RuntimeViewerApp {
    static func main() {
        // **Before `NSApplication` is touched at all.** This registers a default
        // that AppKit reads, and then caches for the life of the process, the
        // first time it customizes the main menu — which assigning `mainMenu`
        // below triggers. See `SystemAutoFillMenuSuppression`.
        SystemAutoFillMenuSuppression.install()

        // Mirrors `NSApplicationMain`, which pushes an autorelease pool over
        // the whole of launch setup and pops it right before `run()`.
        let application = autoreleasepool {
            @Dependency(\.mainMenuController) var mainMenuController

            let application = NSApplication.shared
            // `NSApplication.delegate` is weak; `AppDelegate.shared` is what
            // keeps it alive.
            application.delegate = AppDelegate.shared
            application.setActivationPolicy(.regular)
            application.mainMenu = mainMenuController.makeMainMenu()
            return application
        }
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Not exposed through `@Dependency`: nothing reaches the delegate as a
    /// service. It exists only so `RuntimeViewerApp.main()` above can create it
    /// and hold the strong reference `NSApplication` does not.
    fileprivate static let shared = AppDelegate()

    @Dependency(\.appRouter) private var appRouter
    @Dependency(\.appearanceController) private var appearanceController
    @Dependency(\.debugMenuController) private var debugMenuController
    @Dependency(\.helperServiceVersionChecker) private var helperServiceVersionChecker
    @Dependency(\.mcpService) private var mcpService
    @Dependency(\.settingsLifecycleController) private var settingsLifecycleController
    @Dependency(\.sourceEditorLoader) private var sourceEditorLoader
    @Dependency(\.tabMenuController) private var tabMenuController
    @Dependency(\.updaterService) private var updaterService
    @Dependency(\.simulatorInstallerWindowController) private var simulatorInstallerWindowController
    @Dependency(\.windowLifecycleController) private var windowLifecycleController

    private override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        #if RUNTIMEVIEWER_ARM64E
        runtimeViewerIsARM64EVariant = true
        #endif

        NSToolbarItemViewerOverflowFix.install()

        settingsLifecycleController.loadOnLaunch()
        sourceEditorLoader.startPrewarmingWhenEnabled()
        appearanceController.start()
        debugMenuController.install()
        tabMenuController.install()
        mcpService.start(for: AppMCPBridgeDocumentProvider())
        updaterService.start()
        helperServiceVersionChecker.checkOnLaunch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        settingsLifecycleController.shouldTerminate(sender)
    }

    func applicationWillTerminate(_ notification: Notification) {
        updaterService.stop()
        mcpService.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        windowLifecycleController.shouldTerminateAfterLastWindowClosed
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        windowLifecycleController.handleReopen(for: sender)
    }

    @objc func showSettings(_ sender: Any?) {
        appRouter.trigger(.settings)
    }

    @objc func showSimulatorInstaller(_ sender: Any?) {
        simulatorInstallerWindowController.showWindow(nil)
    }
}
