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
        case serverFrameworkNotFound(PayloadPlatform)
        case targetPlatformUnreadable(pid_t)
        case noPayloadForTargetPlatform(InjectionTargetPlatform)

        public var errorDescription: String? {
            switch self {
            case .serverFrameworkNotFound(let platform):
                return "The \(platform.displayName) server framework is missing from this build of RuntimeViewer."
            case .targetPlatformUnreadable(let processIdentifier):
                return "Could not read what platform process \(processIdentifier) was built for."
            case .noPayloadForTargetPlatform(let platform):
                return "RuntimeViewer has no payload for a \(platform.displayName) process."
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

    // MARK: - Payload selection

    /// Which payload slice a target process needs, read out of its executable.
    ///
    /// A macOS process and an iOS Simulator process on the same Mac share a
    /// `cputype`, so there is no cheaper signal than the target's own
    /// `LC_BUILD_VERSION`. Guessing wrong is not recoverable: dyld refuses the
    /// mismatched slice, and the daemon's remap fallback then projects the
    /// payload into the target anyway, which the kernel kills on page-in.
    public func payloadPlatform(forTargetProcess processIdentifier: pid_t) throws -> PayloadPlatform {
        guard let targetPlatform = InjectionTargetPlatformProbe.platform(ofProcess: processIdentifier) else {
            throw Error.targetPlatformUnreadable(processIdentifier)
        }
        guard let payloadPlatform = PayloadPlatform(targetPlatform: targetPlatform) else {
            throw Error.noPayloadForTargetPlatform(targetPlatform)
        }
        return payloadPlatform
    }

    /// Where a payload slice is installed for targets to load it from.
    ///
    /// Both live directly in `/Library/Frameworks`. A simulator process reaches
    /// them there despite `dyld_sim` rewriting the path: it probes
    /// `<RuntimeRoot>/Library/Frameworks/…` first and the host's own
    /// `/Library/Frameworks/…` second, so an absolute host path still resolves.
    /// (Measured against a live iOS 18.5 simulator daemon, 2026-08-23.)
    ///
    /// The two slices cannot share one bundle. They are the same architecture
    /// and differ only in platform, which is exactly what a fat binary cannot
    /// express — hence the sibling bundles rather than one fat file.
    public func serverFrameworkDestinationURL(for platform: PayloadPlatform) -> URL {
        platform.installedFrameworkURL
    }

    public func isInstalledServerFramework(for platform: PayloadPlatform) -> Bool {
        FileManager.default.fileExists(atPath: serverFrameworkDestinationURL(for: platform).path)
    }

    public func serverFrameworkSourceURL(for platform: PayloadPlatform) -> URL? {
        Bundle.main.url(forResource: platform.frameworkBundleBaseName, withExtension: "framework")
    }

    /// The executable inside an installed payload bundle — the path handed to
    /// the target's `dlopen`.
    public func serverFrameworkExecutableURL(for platform: PayloadPlatform) -> URL? {
        Bundle(url: serverFrameworkDestinationURL(for: platform))?.executableURL
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

    public func installServerFrameworkIfNeeded(for platform: PayloadPlatform) async throws {
        try await installServerFramework(for: platform)
    }

    public func installServerFramework(for platform: PayloadPlatform) async throws {
        guard let sourceURL = serverFrameworkSourceURL(for: platform) else {
            throw Error.serverFrameworkNotFound(platform)
        }
        try await helperServiceManager.ensureConnectedToTool()
        try await helperServiceManager.helperClient.sendToTool(
            request: FileOperationRequest(
                operation: .copy(from: sourceURL, to: serverFrameworkDestinationURL(for: platform))
            )
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
