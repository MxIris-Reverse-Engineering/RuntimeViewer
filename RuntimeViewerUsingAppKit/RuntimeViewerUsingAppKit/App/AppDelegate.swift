import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerCommunication
import RuntimeViewerMCPBridge
import RuntimeViewerSimulatorInstaller

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    @Dependency(\.appRouter) private var appRouter
    @Dependency(\.appearanceController) private var appearanceController
    @Dependency(\.debugMenuController) private var debugMenuController
    @Dependency(\.helperServiceVersionChecker) private var helperServiceVersionChecker
    @Dependency(\.mcpService) private var mcpService
    @Dependency(\.updaterService) private var updaterService
    @Dependency(\.simulatorInstallerWindowController) private var simulatorInstallerWindowController

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        #if RUNTIMEVIEWER_ARM64E
        runtimeViewerIsARM64EVariant = true
        #endif

        NSToolbarItemViewerOverflowFix.install()

        appearanceController.start()
        debugMenuController.install()
        mcpService.start(for: AppMCPBridgeDocumentProvider())
        updaterService.start()
        helperServiceVersionChecker.checkOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        updaterService.stop()
        mcpService.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @IBAction func showSettings(_ sender: Any?) {
        appRouter.trigger(.settings)
    }

    @IBAction func showSimulatorInstaller(_ sender: Any?) {
        simulatorInstallerWindowController.showWindow(nil)
    }
}
