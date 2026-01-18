#if os(macOS)

import Foundation
import SwiftyXPC
import RuntimeViewerCommunication
import OSLog
import Synchronization
import Dependencies
import ServiceManagement

/// Client for injecting code into running applications via the helper service.
public final class RuntimeInjectClient: @unchecked Sendable {
    public static let shared = RuntimeInjectClient()

    private let connectionLock = Mutex<XPCConnection?>(nil)

    private static let logger = Logger(subsystem: "com.mxiris.runtimeviewer", category: "RuntimeInjectClient")

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

    public var isInstalledServerFramework: Bool {
        FileManager.default.fileExists(atPath: serverFrameworkDestinationURL.path)
    }

    public let serverFrameworkDestinationURL = URL(fileURLWithPath: "/Library/Frameworks/RuntimeViewerServer.framework")

    public var serverFrameworkSourceURL: URL? {
        Bundle.main.url(forResource: "RuntimeViewerServer", withExtension: "framework")
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

    public func injectApplication(pid: pid_t, dylibURL: URL) async throws {
        try await connectionIfNeeded().sendMessage(request: InjectApplicationRequest(pid: pid, dylibURL: dylibURL))
    }

    public enum Error: LocalizedError {
        case serverFrameworkNotFound
        public var errorDescription: String? {
            switch self {
            case .serverFrameworkNotFound:
                return "Server framework not found."
            }
        }
    }

    public func installServerFrameworkIfNeeded() async throws {
        try await installServerFramework()
    }

    public func installServerFramework() async throws {
        guard let serverFrameworkSourceURL else {
            throw Error.serverFrameworkNotFound
        }
        try await connectionIfNeeded().sendMessage(request: FileOperationRequest(operation: .copy(from: serverFrameworkSourceURL, to: serverFrameworkDestinationURL)))
    }
}

// MARK: - Dependencies

private enum RuntimeInjectClientKey: DependencyKey {
    static let liveValue = RuntimeInjectClient.shared
}

extension DependencyValues {
    public var runtimeInjectClient: RuntimeInjectClient {
        get { self[RuntimeInjectClientKey.self] }
        set { self[RuntimeInjectClientKey.self] = newValue }
    }
}

#endif
