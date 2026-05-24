#if os(macOS)

import Foundation
import FoundationToolbox
import HelperCommunication
import HelperClient
import RuntimeViewerCommunication
import Dependencies
import ServiceManagement

/// Thin wrapper that routes Catalyst-launch RPCs through the shared lib `HelperClient`
/// owned by `HelperServiceManager`. Connection lifecycle / version reconcile lives in
/// `HelperServiceManager`; this type is kept only so the `@Dependency` injection point
/// `runtimeHelperClient` and its narrow business surface (`launchMacCatalystHelper`)
/// stay stable for callers.
@Loggable
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
                    await reconnect()
                }
                observeStatusChange()
            }
        }
    }

    /// Invalidates the current connection and re-establishes it through
    /// `HelperServiceManager`'s shared lib `HelperClient`.
    public func reconnect() async {
        await helperServiceManager.reconnect()
    }

    public func launchMacCatalystHelper() async throws {
        let callerPID = ProcessInfo.processInfo.processIdentifier
        try await helperServiceManager.ensureConnectedToTool()
        try await helperServiceManager.helperClient.sendToTool(
            request: OpenApplicationRequest(url: RuntimeViewerCatalystHelperLauncher.helperURL, callerPID: callerPID)
        )
    }
}

enum RuntimeViewerCatalystHelperLauncher {
    static let appName = "RuntimeViewerCatalystHelper"
    static let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents").appendingPathComponent("Applications").appendingPathComponent("\(appName).app")
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
