#if os(macOS)

import Foundation
import OSLog
import SwiftyXPC
import ServiceManagement
import RuntimeViewerServiceHelper
import RuntimeViewerCommunication
import Synchronization
import Dependencies

/// Manages the helper service lifecycle including registration, unregistration, and XPC connections.
@Observable
@MainActor
public final class HelperServiceManager {
    public static let shared = HelperServiceManager()

    // MARK: - Static Properties

    public static let legacyPlistFileURL = URL(filePath: "/Library/LaunchDaemons/com.JH.RuntimeViewerService.plist")

    public static let helperServiceDaemon = SMAppService.daemon(plistName: "com.mxiris.runtimeviewer.service.plist")

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
    private let connectionLock = Mutex<XPCConnection?>(nil)

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.mxiris.runtimeviewer", category: "HelperServiceManager")

    private init() {}

    /// Invalidates the current connection and establishes a new one.
    public func reconnect() {
        invalidateConnection()
        do {
            _ = try connectionIfNeeded()
            Self.logger.info("Successfully reconnected to helper service")
        } catch {
            Self.logger.error("Failed to reconnect to helper service: \(error.localizedDescription, privacy: .public)")
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
                Self.logger.error("XPC connection error: \(error.localizedDescription, privacy: .public)")
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
            Self.logger.info("Helper service became enabled")
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
