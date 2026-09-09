#if os(macOS)

import Foundation
import FoundationToolbox
import HelperCommunication
import HelperClient
import ApplicationsServiceInterface
import RuntimeViewerCommunication
import Dependencies
import DependenciesMacros
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
        case catalystHelperNotFound

        public var errorDescription: String? {
            switch self {
            case .message(let message):
                return message
            case .catalystHelperNotFound:
                return "This process has no RuntimeViewer application bundle to launch the Mac Catalyst helper from."
            }
        }
    }

    fileprivate static let shared = RuntimeHelperClient()

    @Dependency(\.helperServiceManager) private var helperServiceManager

    @Dependency(\.runtimeResourceLocator) private var runtimeResourceLocator

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
        guard let helperURL = runtimeResourceLocator.catalystHelperApplicationURL else {
            throw Error.catalystHelperNotFound
        }
        let callerPID = ProcessInfo.processInfo.processIdentifier
        try await helperServiceManager.ensureConnectedToTool()
        try await helperServiceManager.helperClient.sendToTool(
            request: OpenApplicationRequest(url: helperURL, callerPID: callerPID)
        )
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: RuntimeHelperClient.shared)
    public var runtimeHelperClient: RuntimeHelperClient
}

#endif
