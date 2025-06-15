import AppKit
import RuntimeViewerCore
import RuntimeViewerApplication

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        Task {
            do {
                try await RuntimeEngineManager.shared.launchSystemRuntimeEngines()
            } catch {
                NSLog("%@", error as NSError)
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {}

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
