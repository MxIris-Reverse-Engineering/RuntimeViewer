import AppKit
import FoundationToolbox
import ServiceManagement
import RuntimeViewerArchitectures
import RuntimeViewerHelperClient
import DependenciesMacros

@MainActor
@Loggable(.private)
final class HelperServiceVersionChecker {
    fileprivate static let shared = HelperServiceVersionChecker()

    @Dependency(\.helperServiceManager) private var helperServiceManager

    private init() {}

    func checkOnLaunch() {
        Task { @MainActor in
            let result = await helperServiceManager.checkServiceVersionAndReinstallIfNeeded()
            switch result {
            case .reinstalled:
                presentReinstalledAlert()
            case .reinstallFailed(let error):
                presentReinstallFailedAlert(error: error)
            case .versionQueryFailed(let error):
                // Transient XPC error — do NOT unregister/reinstall. Just log and move on;
                // the next launch (or a user-initiated reinstall from Settings) can retry.
                #log(.info, "Helper service version query failed transiently, skipping automatic reinstall: \(error.localizedDescription, privacy: .public)")
            case .upToDate, .mismatchButNotEnabled:
                break
            }
        }
    }

    private func presentReinstalledAlert() {
        let alert = NSAlert()
        alert.messageText = "Helper Service Updated"
        alert.informativeText = "The helper service has been reinstalled due to a version mismatch. Please restart the application for the changes to take effect."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            relaunchApplication()
        }
    }

    private func presentReinstallFailedAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Helper Service Reinstall Failed"
        alert.informativeText = "The helper service needs to be reinstalled due to a version mismatch, but the reinstall failed: \(error.localizedDescription)\n\nYou can try again from Settings > Helper Service."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Dismiss")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func relaunchApplication() {
        let executableURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: executableURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { HelperServiceVersionChecker.shared })
    var helperServiceVersionChecker: HelperServiceVersionChecker
}
