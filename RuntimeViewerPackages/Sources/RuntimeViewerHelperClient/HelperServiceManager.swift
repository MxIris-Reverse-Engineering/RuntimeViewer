#if os(macOS)

import Foundation
import FoundationToolbox
import ServiceManagement
import RuntimeViewerServiceHelper
import HelperCommunication
import HelperClient
import RuntimeViewerCommunication
import Dependencies

/// Manages the helper service lifecycle including registration, unregistration, and XPC connections.
///
/// Connection management is delegated to lib `HelperClient` (actor), and daemon install/unregister
/// flow to lib `SMAppServiceDaemonInstaller` (actor). This class keeps only the Observable status
/// shell so the Settings UI keeps reacting to `status` / `message` / `legacyMessage` changes.
@Loggable
@Observable
@MainActor
public final class HelperServiceManager {
    public static let shared = HelperServiceManager()

    // MARK: - Static Properties

    public static let legacyPlistFileURL = URL(filePath: "/Library/LaunchDaemons/com.JH.RuntimeViewerService.plist")

    #if DEBUG
    public static let helperServiceDaemon = SMAppService.daemon(plistName: "dev.mxiris.runtimeviewer.service.plist")
    private static let helperServicePlistName = "dev.mxiris.runtimeviewer.service.plist"
    #else
    public static let helperServiceDaemon = SMAppService.daemon(plistName: "com.mxiris.runtimeviewer.service.plist")
    private static let helperServicePlistName = "com.mxiris.runtimeviewer.service.plist"
    #endif

    // MARK: - Observable State

    public private(set) var status: SMAppService.Status = .notRegistered

    public private(set) var isLoading: Bool = false

    public private(set) var message: String = "Checking..."

    public private(set) var isLegacyServiceInstalled: Bool = false

    public private(set) var isLegacyLoading: Bool = false

    public private(set) var legacyMessage: String = "Checking..."

    // MARK: - Computed Properties

    public var isEnabled: Bool {
        status == .enabled
    }

    public var canUninstallLegacy: Bool {
        status == .enabled
    }

    // MARK: - Lib delegates

    /// Shared lib `HelperClient` actor used by `HelperServiceManager`,
    /// `RuntimeHelperClient`, and `RuntimeInjectClient`. All daemon-bound business RPCs
    /// route through this single instance so there's only one XPC connection to the tool
    /// at a time.
    @ObservationIgnored
    public let helperClient = HelperClient()

    @ObservationIgnored
    private let installer: SMAppServiceDaemonInstaller

    @ObservationIgnored
    private var hasConnectedToTool: Bool = false

    private init() {
        self.installer = SMAppServiceDaemonInstaller(plistName: Self.helperServicePlistName)
    }

    // MARK: - Connection (lazy)

    /// Ensures the shared `helperClient` has an active tool connection. Idempotent — once
    /// connected, subsequent calls are no-ops until `invalidateConnection()` resets the flag.
    public func ensureConnectedToTool() async throws {
        if hasConnectedToTool { return }
        try await helperClient.connectToTool(
            machServiceName: RuntimeViewerMachServiceName,
            isPrivilegedHelperTool: true
        )
        hasConnectedToTool = true
    }

    /// Reconnect by clearing the connect flag and re-running `connectToTool`. The lib
    /// actor overrides its internal connection in place, so the previous XPC channel
    /// is dropped automatically.
    public func reconnect() async {
        hasConnectedToTool = false
        do {
            try await ensureConnectedToTool()
            #log(.info, "Successfully reconnected to helper service")
        } catch {
            #log(.error, "Failed to reconnect to helper service: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Marks the connection as invalid; the next `ensureConnectedToTool()` will re-open it.
    public func invalidateConnection() {
        hasConnectedToTool = false
    }

    // MARK: - Status Management

    public func refreshAllStatus() async {
        let previousStatus = status
        checkLegacyServiceStatus()
        await manageHelperService(action: .status)
        logStatusChangeIfNeeded(previousStatus: previousStatus)
    }

    public func checkLegacyServiceStatus() {
        isLegacyServiceInstalled = FileManager.default.fileExists(atPath: Self.legacyPlistFileURL.path)

        if isLegacyServiceInstalled {
            if status == .enabled {
                legacyMessage = "Legacy helper service detected. Click Uninstall to remove it."
            } else {
                legacyMessage = "Legacy helper service detected. Please install the new helper service first, then uninstall the legacy version."
            }
        } else {
            legacyMessage = "No legacy helper service installed."
        }
    }

    // MARK: - Helper Service Management

    public enum Action {
        case status
        case install
        case uninstall
    }

    public func manageHelperService(action: Action = .status) async {
        isLoading = action != .status
        defer { isLoading = false }

        var occurredError: NSError?
        let previousStatus = Self.helperServiceDaemon.status

        switch action {
        case .install:
            switch Self.helperServiceDaemon.status {
            case .requiresApproval:
                message = "Registered but requires enabling in System Settings > Login Items."
                SMAppService.openSystemSettingsLoginItems()
            case .enabled:
                message = "Service is already enabled."
            default:
                do {
                    try await installer.register()
                    if Self.helperServiceDaemon.status == .requiresApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                } catch let nsError as NSError {
                    occurredError = nsError
                    if nsError.code == 1 {
                        message = "Permission required. Enable in System Settings > Login Items."
                        SMAppService.openSystemSettingsLoginItems()
                    } else {
                        message = "Installation failed: \(nsError.localizedDescription)"
                    }
                }
            }

        case .uninstall:
            do {
                try await installer.unregister()
            } catch let nsError as NSError {
                occurredError = nsError
            }

        case .status:
            break
        }

        updateStatusMessages(occurredError: occurredError)
        status = Self.helperServiceDaemon.status
        logStatusChangeIfNeeded(previousStatus: previousStatus)
    }

    private func updateStatusMessages(occurredError: NSError?) {
        if let nsError = occurredError {
            switch nsError.code {
            case kSMErrorAlreadyRegistered:
                message = "Service is already registered and enabled."
            case kSMErrorLaunchDeniedByUser:
                message = "User denied permission. Enable in System Settings > Login Items."
            case kSMErrorInvalidSignature:
                message = "Invalid signature, ensure proper signing on the application and helper service."
            case 1:
                message = "Authorization required in Settings > Login Items."
            default:
                message = "Operation failed: \(nsError.localizedDescription)"
            }
        } else {
            switch Self.helperServiceDaemon.status {
            case .notRegistered:
                message = "Service hasn't been registered. You may register it now."
            case .enabled:
                message = "Service successfully registered and eligible to run."
            case .requiresApproval:
                message = "Service registered but requires user approval in Settings > Login Items."
            case .notFound:
                message = "Service is not installed."
            @unknown default:
                message = "Unknown service status (\(Self.helperServiceDaemon.status))."
            }
        }
    }

    private func logStatusChangeIfNeeded(previousStatus: SMAppService.Status) {
        let currentStatus = Self.helperServiceDaemon.status
        if currentStatus == .enabled && previousStatus != .enabled {
            #log(.info, "Helper service became enabled")
        }
    }

    // MARK: - Legacy Helper Service Management

    public func uninstallLegacyService() async {
        guard status == .enabled else {
            legacyMessage = "Please install the new helper service first before uninstalling the legacy version."
            return
        }

        isLegacyLoading = true
        defer { isLegacyLoading = false }

        do {
            // Step 1: Stop the legacy service process via SMJobRemove
            try? LegacyHelperTool.uninstall(withServiceName: "com.JH.RuntimeViewerService")

            // Step 2: Delete the legacy plist file via new helper service (requires root)
            try await ensureConnectedToTool()
            try await helperClient.sendToTool(request: FileOperationRequest(operation: .remove(url: Self.legacyPlistFileURL)))

            checkLegacyServiceStatus()
            if !isLegacyServiceInstalled {
                legacyMessage = "Legacy helper service successfully uninstalled."
            }
        } catch {
            legacyMessage = "Failed to uninstall legacy service: \(error.localizedDescription)"
        }
    }

    // MARK: - Version Check

    /// Result of checking the running service's version against the app's expected version.
    public enum ServiceVersionCheckResult {
        /// Versions match, no action needed.
        case upToDate
        /// Version mismatch detected and service was reinstalled. App should restart.
        case reinstalled
        /// Version mismatch detected but service is not enabled, cannot reinstall automatically.
        case mismatchButNotEnabled
        /// Version query failed with a transient error (e.g. XPC hiccup, connection refused).
        /// No action was taken; the daemon is left alone and the caller should retry on the next launch.
        case versionQueryFailed(any Error)
        /// Version mismatch was detected and unregister succeeded, but `daemon.register()` threw.
        /// The daemon may now be in an inconsistent state; the caller should surface the error to the user.
        case reinstallFailed(any Error)
    }

    /// Checks whether the running helper service version matches the app's expected version.
    ///
    /// Delegates the version query to lib `HelperClient.fetchToolVersion()` and the
    /// `unexpectedMessage`-vs-transient classification to
    /// `HelperClient.errorIndicatesOutdatedPeer(_:)`. Install/unregister go through lib
    /// `SMAppServiceDaemonInstaller`. On mismatch + service enabled, the daemon is
    /// unregistered, paused briefly, and re-registered so the new binary picks up.
    public func checkServiceVersionAndReinstallIfNeeded() async -> ServiceVersionCheckResult {
        let serviceVersion: String?
        do {
            try await ensureConnectedToTool()
            serviceVersion = try await helperClient.fetchToolVersion()
        } catch {
            if Self.errorIndicatesOutdatedBinary(error) {
                #log(.info, "Fetch version failed with 'unhandled message' error — treating as outdated binary: \(error.localizedDescription, privacy: .public)")
                serviceVersion = nil
            } else {
                #log(.error, "Failed to fetch service version (treating as transient, no action): \(error.localizedDescription, privacy: .public)")
                return .versionQueryFailed(error)
            }
        }

        if let serviceVersion {
            let expectedVersion = RuntimeViewerServiceVersion
            guard serviceVersion != expectedVersion else {
                #log(.info, "Service version matches: \(serviceVersion, privacy: .public)")
                return .upToDate
            }
            #log(.info, "Service version mismatch — running: \(serviceVersion, privacy: .public), expected: \(expectedVersion, privacy: .public)")
        } else {
            #log(.info, "Service does not support version query, treating as outdated")
        }

        guard Self.helperServiceDaemon.status == .enabled else {
            #log(.info, "Service is not enabled (status: \(String(describing: Self.helperServiceDaemon.status), privacy: .public)), cannot reinstall automatically")
            return .mismatchButNotEnabled
        }

        // Uninstall the outdated service
        invalidateConnection()
        do {
            try await installer.unregister()
            #log(.info, "Successfully unregistered outdated service")
        } catch {
            #log(.error, "Failed to unregister service: \(error.localizedDescription, privacy: .public)")
            // Proceed anyway; register() below may still succeed from a .notRegistered state.
        }

        // SMAppService bookkeeping on disk can lag behind the unregister await —
        // without this short pause, the immediately-following register() call
        // occasionally fails with a "already registered" error. See FB-radar TBD.
        try? await Task.sleep(for: .seconds(1))

        // Reinstall the service
        do {
            try await installer.register()
            #log(.info, "Successfully re-registered service")
        } catch {
            #log(.error, "Failed to re-register service: \(error.localizedDescription, privacy: .public)")
            status = Self.helperServiceDaemon.status
            updateStatusMessages(occurredError: error as NSError)
            return .reinstallFailed(error)
        }

        status = Self.helperServiceDaemon.status
        updateStatusMessages(occurredError: nil)
        return .reinstalled
    }

    /// Returns `true` only when the thrown error tells us the running helper binary does not
    /// recognize the version query message (i.e. predates the version check feature). Every other
    /// error — connection refused, interrupted, invalid, generic XPC failure — is treated as
    /// transient and must NOT trigger an automatic reinstall.
    ///
    /// Delegates to `HelperClient.errorIndicatesOutdatedPeer(_:)` so the discriminator stays in
    /// lock-step with the shared lib implementation.
    private static func errorIndicatesOutdatedBinary(_ error: any Error) -> Bool {
        HelperClient.errorIndicatesOutdatedPeer(error)
    }

    // MARK: - XPC Operations

    /// Sends a file operation request to the helper service.
    public func performFileOperation(_ operation: FileOperation) async throws {
        try await ensureConnectedToTool()
        try await helperClient.sendToTool(request: FileOperationRequest(operation: operation))
    }
}

// MARK: - Dependencies

private enum HelperServiceManagerKey: @preconcurrency DependencyKey {
    @MainActor static let liveValue = HelperServiceManager.shared
}

extension DependencyValues {
    public var helperServiceManager: HelperServiceManager {
        get { self[HelperServiceManagerKey.self] }
        set { self[HelperServiceManagerKey.self] = newValue }
    }
}

#endif
