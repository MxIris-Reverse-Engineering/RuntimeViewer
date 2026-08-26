import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerCommunication
import RuntimeViewerMCPBridge
import RuntimeViewerSimulatorInstaller

@main
@MainActor
enum App {
    static func main() {
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
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
