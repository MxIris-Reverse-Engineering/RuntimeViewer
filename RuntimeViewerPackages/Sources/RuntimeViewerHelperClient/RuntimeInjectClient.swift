#if os(macOS)

import Foundation
import FoundationToolbox
import HelperCommunication
import HelperClient
import FilesServiceInterface
import InjectionServiceInterface
import InjectedEndpointRegistryServiceInterface
import RuntimeViewerCommunication
import Dependencies
import ServiceManagement

/// Thin wrapper that routes injection / framework-install / injected-endpoint registry
/// RPCs through the shared lib `HelperClient` owned by `HelperServiceManager`.
@Loggable
public final class RuntimeInjectClient: @unchecked Sendable {
    public enum Error: LocalizedError {
        case serverFrameworkNotFound
        public var errorDescription: String? {
            switch self {
            case .serverFrameworkNotFound:
                return "Server framework not found."
            }
        }
    }

    fileprivate static let shared = RuntimeInjectClient()

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

    public func reconnect() async {
        await helperServiceManager.reconnect()
    }

    public let serverFrameworkDestinationURL = URL(fileURLWithPath: "/Library/Frameworks/RuntimeViewerServer.framework")

    public var isInstalledServerFramework: Bool {
        FileManager.default.fileExists(atPath: serverFrameworkDestinationURL.path)
    }

    public var serverFrameworkSourceURL: URL? {
        Bundle.main.url(forResource: "RuntimeViewerServer", withExtension: "framework")
    }

    // MARK: - Injection

    public func injectApplication(pid: pid_t, dylibURL: URL) async throws {
        try await helperServiceManager.ensureConnectedToTool()
        try await helperServiceManager.helperClient.sendToTool(
            request: InjectApplicationRequest(pid: pid, dylibURL: dylibURL)
        )
    }

    // MARK: - Framework install

    public func installServerFrameworkIfNeeded() async throws {
        try await installServerFramework()
    }

    public func installServerFramework() async throws {
        guard let serverFrameworkSourceURL else {
            throw Error.serverFrameworkNotFound
        }
        try await helperServiceManager.ensureConnectedToTool()
        try await helperServiceManager.helperClient.sendToTool(
            request: FileOperationRequest(operation: .copy(from: serverFrameworkSourceURL, to: serverFrameworkDestinationURL))
        )
    }

    // MARK: - Injected Endpoint Registry

    /// Registers an injected app's XPC endpoint with the daemon's
    /// `InjectedEndpointRegistryService`.
    public func registerInjectedEndpoint(pid: pid_t, appName: String, bundleIdentifier: String, endpoint: HelperPeerEndpoint) async throws {
        try await helperServiceManager.ensureConnectedToTool()
        try await helperServiceManager.helperClient.sendToTool(
            request: RegisterInjectedEndpointRequest(
                pid: pid,
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                endpoint: endpoint
            )
        )
    }

    /// Fetches all registered injected app endpoints from the daemon.
    public func fetchAllInjectedEndpoints() async throws -> [InjectedEndpointInfo] {
        try await helperServiceManager.ensureConnectedToTool()
        let response: FetchAllInjectedEndpointsRequest.Response = try await helperServiceManager.helperClient.sendToTool(
            request: FetchAllInjectedEndpointsRequest()
        )
        return response.endpoints
    }

    /// Removes an injected app's endpoint from the daemon.
    public func removeInjectedEndpoint(pid: pid_t) async throws {
        try await helperServiceManager.ensureConnectedToTool()
        try await helperServiceManager.helperClient.sendToTool(
            request: RemoveInjectedEndpointRequest(pid: pid)
        )
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
