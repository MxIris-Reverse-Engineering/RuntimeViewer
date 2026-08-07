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
import DependenciesMacros
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

    /// Injects `dylibURL` into `pid`.
    ///
    /// How it gets loaded — a `dlopen` inside the target, or a `mach_vm_remap`
    /// projection of the payload's segments — is decided by the daemon, which
    /// probes the target's sandbox and code-signing status. Deliberately not
    /// decided here: the two halves would drift apart, and the app cannot see
    /// anything the daemon cannot.
    ///
    /// `remapEntrySymbol` is used only if the daemon takes the remap path,
    /// where dyld's constructor pass never runs and an exported
    /// `void *(*)(void *)` entry is the only way in.
    public func injectApplication(pid: pid_t, dylibURL: URL, remapEntrySymbol: String? = nil) async throws {
        try await helperServiceManager.ensureConnectedToTool()
        try await helperServiceManager.helperClient.sendToTool(
            request: InjectApplicationRequest(pid: pid, dylibURL: dylibURL, remapEntrySymbol: remapEntrySymbol)
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

extension DependencyValues {
    @DependencyEntry(liveValue: RuntimeInjectClient.shared)
    public var runtimeInjectClient: RuntimeInjectClient
}

#endif
