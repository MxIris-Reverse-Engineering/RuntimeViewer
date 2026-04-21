import AppKit
import Sparkle
import FoundationToolbox
import RuntimeViewerSettings
import RuntimeViewerSettingsUI
import Dependencies
import OSLog

@Loggable(.private)
@MainActor
final class UpdaterService: NSObject {
    static let shared = UpdaterService()

    @Dependency(\.settings) private var settings

    private var updaterController: SPUStandardUpdaterController?
    private var settingsObservationTask: Task<Void, Never>?

    private override init() { super.init() }

    func start() {
        guard updaterController == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        updaterController = controller
        installCheckForUpdatesMenuItem(target: controller)
        applyInitialBindings(to: controller.updater)
        startSettingsObservation(for: controller.updater)
        if isDebugBuild {
            #log(.info, "UpdaterService.start() — Debug build detected; initial automatic check suppressed")
            controller.updater.automaticallyChecksForUpdates = false
        }
        installSettingsUIProviders()
    }

    func stop() {
        settingsObservationTask?.cancel()
        settingsObservationTask = nil
        updaterController = nil
        UpdateStatusReader.currentVersionDisplayProvider = { "—" }
        UpdateStatusReader.lastCheckDateProvider = { nil }
        UpdateStatusReader.isSessionInProgressProvider = { false }
        UpdateStatusReader.triggerCheckAction = {}
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    var lastUpdateCheckDate: Date? {
        updaterController?.updater.lastUpdateCheckDate
    }

    var isSessionInProgress: Bool {
        updaterController?.updater.sessionInProgress ?? false
    }

    var currentVersionDisplay: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - Private

    private var isDebugBuild: Bool {
        (Bundle.main.infoDictionary?["CFBundleName"] as? String)?.contains("Debug") == true
    }

    private func installCheckForUpdatesMenuItem(target: SPUStandardUpdaterController) {
        guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }
        if appMenu.items.contains(where: { $0.action == #selector(SPUStandardUpdaterController.checkForUpdates(_:)) }) {
            return
        }
        let aboutIndex = appMenu.items.firstIndex {
            $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        } ?? 0
        let item = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = target
        appMenu.insertItem(item, at: aboutIndex + 1)
    }

    private func applyInitialBindings(to updater: SPUUpdater) {
        let update = settings.update
        updater.automaticallyChecksForUpdates = update.automaticallyChecks
        updater.automaticallyDownloadsUpdates = update.automaticallyDownloads
        updater.updateCheckInterval = update.checkInterval.timeInterval
    }

    private func installSettingsUIProviders() {
        UpdateStatusReader.currentVersionDisplayProvider = { [weak self] in
            self?.currentVersionDisplay ?? "—"
        }
        UpdateStatusReader.lastCheckDateProvider = { [weak self] in
            self?.lastUpdateCheckDate
        }
        UpdateStatusReader.isSessionInProgressProvider = { [weak self] in
            self?.isSessionInProgress ?? false
        }
        UpdateStatusReader.triggerCheckAction = { [weak self] in
            self?.checkForUpdates()
        }
    }

    private func startSettingsObservation(for updater: SPUUpdater) {
        // Re-apply Settings.update.* to updater whenever the observable
        // settings snapshot changes.
        settingsObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    _ = withObservationTracking {
                        _ = self?.settings.update
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard let self else { return }
                self.applyInitialBindings(to: updater)
            }
        }
    }
}

extension UpdaterService: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated {
            settings.update.allowedChannels
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        MainActor.assumeIsolated {
            #log(.error, "Sparkle updater aborted: \(error.localizedDescription, privacy: .public)")
        }
    }
}
