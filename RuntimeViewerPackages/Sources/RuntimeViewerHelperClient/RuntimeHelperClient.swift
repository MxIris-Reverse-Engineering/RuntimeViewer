#if os(macOS)

import Foundation
import SwiftyXPC
import RuntimeViewerCommunication
import OSLog
import Synchronization
import Dependencies
import ServiceManagement

/// Client for communicating with the RuntimeViewer helper service.
public final class RuntimeHelperClient: @unchecked Sendable {
    public enum Error: LocalizedError {
        case message(String)

        public var errorDescription: String? {
            switch self {
            case .message(let message):
                return message
            }
        }
    }

    public static let shared = RuntimeHelperClient()

    private let connectionLock = Mutex<XPCConnection?>(nil)

    private static let logger = Logger(subsystem: "com.mxiris.runtimeviewer", category: "RuntimeHelperClient")

    @Dependency(\.helperServiceManager) private var helperServiceManager

    private init() {
        Task { @MainActor in
            observeStatusChange()
        }
    }

    @MainActor
    private func observeStatusChange() {
        withObservationTracking {
            _ = helperServiceManager.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if helperServiceManager.status == .enabled {
                    reconnect()
                }
                observeStatusChange()
            }
        }
    }

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
}

// MARK: - Dependencies

private enum RuntimeHelperClientKey: DependencyKey {
    static let liveValue = RuntimeHelperClient.shared
}

extension DependencyValues {
    public var runtimeHelperClient: RuntimeHelperClient {
        get { self[RuntimeHelperClientKey.self] }
        set { self[RuntimeHelperClientKey.self] = newValue }
    }
}

#endif
