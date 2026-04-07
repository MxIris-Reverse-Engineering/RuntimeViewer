#if os(macOS)

import Foundation
import FoundationToolbox
import SwiftyXPC
import ServiceManagement
import RuntimeViewerServiceHelper
import RuntimeViewerCommunication
import Synchronization
import Dependencies

/// Manages the helper service lifecycle including registration, unregistration, and XPC connections.
@Loggable
@Observable
@MainActor
public final class HelperServiceManager {
    public static let shared = HelperServiceManager()

    // MARK: - Static Properties

    public static let legacyPlistFileURL = URL(filePath: "/Library/LaunchDaemons/com.JH.RuntimeViewerService.plist")

    #if DEBUG
    public static let helperServiceDaemon = SMAppService.daemon(plistName: "dev.mxiris.runtimeviewer.service.plist")
    #else
    public static let helperServiceDaemon = SMAppService.daemon(plistName: "com.mxiris.runtimeviewer.service.plist")
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

    // MARK: - XPC Connection

    @ObservationIgnored
    private let connectionLock = Synchronization.Mutex<XPCConnection?>(nil)

    private init() {}

    /// Invalidates the current connection and establishes a new one.
    public func reconnect() {
        invalidateConnection()
        do {
            _ = try connectionIfNeeded()
            #log(.info,"Successfully reconnected to helper service")
        } catch {
            #log(.error,"Failed to reconnect to helper service: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Invalidates the current connection without reconnecting.
    public func invalidateConnection() {
        connectionLock.withLock { connection in
            connection?.cancel()
            connection = nil
        }
    }

    private func connectionIfNeeded() throws -> XPCConnection {
        try connectionLock.withLock { connection in
            if let currentConnection = connection {
                return currentConnection
            }

            let newConnection = try XPCConnection(type: .remoteMachService(serviceName: RuntimeViewerMachServiceName, isPrivilegedHelperTool: true))
            newConnection.errorHandler = { [weak self] _, error in
                #log(.error,"XPC connection error: \(error.localizedDescription, privacy: .public)")
                self?.connectionLock.withLock { conn in
                    conn = nil
                }
            }
            newConnection.activate()
            connection = newConnection
            return newConnection
        }
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
        let daemon = Self.helperServiceDaemon
        let previousStatus = daemon.status

        switch action {
        case .install:
            switch daemon.status {
            case .requiresApproval:
                message = "Registered but requires enabling in System Settings > Login Items."
                SMAppService.openSystemSettingsLoginItems()
            case .enabled:
                message = "Service is already enabled."
            default:
                do {
                    try daemon.register()
                    if daemon.status == .requiresApproval {
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
                try await daemon.unregister()
            } catch let nsError as NSError {
                occurredError = nsError
            }

        case .status:
            break
        }

        updateStatusMessages(occurredError: occurredError)
        status = daemon.status
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
            let daemon = Self.helperServiceDaemon
            switch daemon.status {
            case .notRegistered:
                message = "Service hasn't been registered. You may register it now."
            case .enabled:
                message = "Service successfully registered and eligible to run."
            case .requiresApproval:
                message = "Service registered but requires user approval in Settings > Login Items."
            case .notFound:
                message = "Service is not installed."
            @unknown default:
                message = "Unknown service status (\(daemon.status))."
            }
        }
    }

    private func logStatusChangeIfNeeded(previousStatus: SMAppService.Status) {
        let currentStatus = Self.helperServiceDaemon.status
        if currentStatus == .enabled && previousStatus != .enabled {
            #log(.info,"Helper service became enabled")
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
            let connection = try connectionIfNeeded()
            try await connection.sendMessage(request: FileOperationRequest(operation: .remove(url: Self.legacyPlistFileURL)))

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
    }

    /// Checks whether the running helper service version matches the app's expected version.
    ///
    /// If the versions differ and the service is currently enabled, this method automatically
    /// uninstalls and reinstalls the service. The caller should prompt the user to restart.
    ///
    /// When the version query itself fails (e.g. the running service predates the version
    /// check mechanism and doesn't handle `FetchServiceVersionRequest`), the service is
    /// also treated as outdated and reinstalled if currently enabled.
    public func checkServiceVersionAndReinstallIfNeeded() async -> ServiceVersionCheckResult {
        let serviceVersion: String?
        do {
            let connection = try connectionIfNeeded()
            let response: FetchServiceVersionRequest.Response = try await connection.sendMessage(request: FetchServiceVersionRequest())
            serviceVersion = response.version
        } catch {
            #log(.error, "Failed to fetch service version: \(error.localizedDescription, privacy: .public)")
            // Old service binaries don't have the version handler, treat as outdated.
            serviceVersion = nil
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

        let daemon = Self.helperServiceDaemon
        guard daemon.status == .enabled else {
            #log(.info, "Service is not enabled (status: \(String(describing: daemon.status), privacy: .public)), cannot reinstall automatically")
            return .mismatchButNotEnabled
        }

        // Uninstall the outdated service
        do {
            invalidateConnection()
            try await daemon.unregister()
            #log(.info, "Successfully unregistered outdated service")
        } catch {
            #log(.error, "Failed to unregister service: \(error.localizedDescription, privacy: .public)")
        }

        try? await Task.sleep(for: .seconds(1))
        
        // Reinstall the service
        do {
            try daemon.register()
            #log(.info, "Successfully re-registered service")
        } catch {
            #log(.error, "Failed to re-register service: \(error.localizedDescription, privacy: .public)")
        }

        status = daemon.status
        updateStatusMessages(occurredError: nil)
        return .reinstalled
    }

    // MARK: - XPC Operations

    /// Sends a file operation request to the helper service.
    public func performFileOperation(_ operation: FileOperation) async throws {
        let connection = try connectionIfNeeded()
        try await connection.sendMessage(request: FileOperationRequest(operation: operation))
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
