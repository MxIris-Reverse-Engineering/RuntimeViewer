import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerCommunication
import RuntimeViewerMCPBridge
import RuntimeViewerSimulatorInstaller

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    fileprivate static let shared = AppDelegate()

    @Dependency(\.appRouter) private var appRouter
    @Dependency(\.appearanceController) private var appearanceController
    @Dependency(\.commandLineHostController) private var commandLineHostController
    @Dependency(\.debugMenuController) private var debugMenuController
    @Dependency(\.helperServiceVersionChecker) private var helperServiceVersionChecker
    @Dependency(\.mcpService) private var mcpService
    @Dependency(\.runtimeConnectionNotificationService) private var runtimeConnectionNotificationService
    @Dependency(\.settingsLifecycleController) private var settingsLifecycleController
    @Dependency(\.sourceEditorLoader) private var sourceEditorLoader
    @Dependency(\.tabMenuController) private var tabMenuController
    @Dependency(\.updaterService) private var updaterService
    @Dependency(\.simulatorInstallerWindowController) private var simulatorInstallerWindowController
    @Dependency(\.windowLifecycleController) private var windowLifecycleController

    private override init() {
        super.init()
    }
    
    
    static func main() {
        // Has to run before AppKit does anything, not from a lifecycle callback. Window restoration
        // is driven by the open-application Apple Event inside `NSApplication.run()`, which lands
        // *before* `applicationDidFinishLaunching`: the restored document window builds its
        // coordinator, which resolves `RuntimeEngineManager` and through it `HelperServiceManager`,
        // whose installer stores the `SMAppService` built from `RuntimeViewerMachServiceName`.
        // Selecting the variant afterwards left that installer pinned to the non-arm64e daemon, so
        // installing the helper failed with "Unable to read plist" while every status read, being
        // recomputed, looked correct. See
        // Documentations/ResolvedIssues/2026-09-18-arm64e-variant-selected-after-window-restoration.md.
        #if RUNTIMEVIEWER_ARM64E
        runtimeViewerIsARM64EVariant = true
        #endif

        SystemAutoFillMenuSuppression.install()
        let application = autoreleasepool {
            @Dependency(\.mainMenuController) var mainMenuController

            let application = NSApplication.shared
            application.delegate = AppDelegate.shared
            application.setActivationPolicy(.regular)
            application.mainMenu = mainMenuController.makeMainMenu()
            return application
        }
        application.run()
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSToolbarItemViewerOverflowFix.install()
        CustomToolTipManager.install()

        settingsLifecycleController.loadOnLaunch()
        runtimeConnectionNotificationService.start()
        sourceEditorLoader.startPrewarmingWhenEnabled()
        appearanceController.start()
        debugMenuController.install()
        tabMenuController.install()
        mcpService.start(for: AppMCPBridgeDocumentProvider())
        commandLineHostController.start()
        updaterService.start()
        helperServiceVersionChecker.checkOnLaunch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        settingsLifecycleController.shouldTerminate(sender)
    }

    func applicationWillTerminate(_ notification: Notification) {
        updaterService.stop()
        commandLineHostController.stop()
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
