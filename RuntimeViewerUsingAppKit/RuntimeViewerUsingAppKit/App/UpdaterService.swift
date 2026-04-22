import AppKit
import Sparkle
import Synchronization
import FoundationToolbox
import RuntimeViewerSettings
import Dependencies
import OSLog

@Loggable(.private)
@MainActor
final class UpdaterService: NSObject {
    static let shared = UpdaterService()

    @Dependency(\.settings) private var settings
    @Dependency(\.updaterClient) private var updaterClient

    private var updaterController: SPUStandardUpdaterController?
    private var checkForUpdatesMenuItem: NSMenuItem?

    /// Sparkle can invoke SPUUpdaterDelegate callbacks off the main queue, so a
    /// nonisolated read path must avoid MainActor-isolated storage. The
    /// observation loop refreshes this cache on every settings change.
    private let allowedChannelsStorage = Synchronization.Mutex<Set<String>>([])

    override private init() { super.init() }

    func start() {
        guard updaterController == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        updaterController = controller

        installCheckForUpdatesMenuItem(target: controller)
        bindClient(to: controller)
        applySettings(to: controller.updater)
        observeSettings(for: controller.updater)
    }

    func stop() {
        if let item = checkForUpdatesMenuItem {
            item.menu?.removeItem(item)
            checkForUpdatesMenuItem = nil
        }
        updaterClient.checkForUpdates = {}
        updaterController = nil
    }

    // MARK: - Menu

    private func installCheckForUpdatesMenuItem(target: SPUStandardUpdaterController) {
        guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else {
            #log(.error, "UpdaterService: application menu missing; 'Check for Updates…' not installed")
            return
        }
        if appMenu.items.contains(where: {
            $0.action == #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        }) {
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
        checkForUpdatesMenuItem = item
    }

    // MARK: - Client bridge

    private func bindClient(to controller: SPUStandardUpdaterController) {
        let updater = controller.updater
        updaterClient.setCurrentVersionDisplay(UpdaterClient.defaultVersionDisplay())
        updaterClient.setLastCheckDate(updater.lastUpdateCheckDate)
        updaterClient.setIsSessionInProgress(updater.sessionInProgress)
        updaterClient.setLastCheckError(nil)
        updaterClient.checkForUpdates = { [weak controller] in
            controller?.checkForUpdates(nil)
        }
    }

    // MARK: - Settings → Sparkle

    private func applySettings(to updater: SPUUpdater) {
        let update = settings.update
        // Keep the nonisolated allowedChannels cache in sync on every write.
        allowedChannelsStorage.withLock { $0 = update.allowedChannels }
        #if DEBUG
        // Debug builds never check automatically regardless of the stored user
        // setting, to avoid surprise background downloads during development.
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        #else
        updater.automaticallyChecksForUpdates = update.automaticallyChecks
        updater.automaticallyDownloadsUpdates = update.automaticallyDownloads
        #endif
        updater.updateCheckInterval = update.checkInterval.timeInterval
    }

    /// Recursive `withObservationTracking`: re-apply on each change, then
    /// re-register for the next round. `stop()` nils `updaterController`,
    /// which makes subsequent `onChange` fires a no-op and terminates the
    /// recursion.
    private func observeSettings(for updater: SPUUpdater) {
        guard updaterController != nil else { return }
        withObservationTracking {
            _ = settings.update
        } onChange: { [weak self, weak updater] in
            Task { @MainActor [weak self, weak updater] in
                guard let self, let updater,
                      self.updaterController != nil else { return }
                self.applySettings(to: updater)
                self.observeSettings(for: updater)
            }
        }
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterService: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        allowedChannelsStorage.withLock { $0 }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let message = error.localizedDescription
        #log(.error, "Sparkle updater aborted: \(message, privacy: .public)")
        Task { @MainActor [weak self] in
            self?.updaterClient.setLastCheckError(error)
            self?.updaterClient.setIsSessionInProgress(false)
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        Task { @MainActor [weak self, weak updater] in
            guard let self, let updater else { return }
            self.updaterClient.setLastCheckDate(updater.lastUpdateCheckDate)
            self.updaterClient.setIsSessionInProgress(updater.sessionInProgress)
            self.updaterClient.setLastCheckError(error)
        }
    }
}
