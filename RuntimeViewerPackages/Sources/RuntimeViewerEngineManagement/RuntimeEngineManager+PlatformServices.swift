import Combine
import Foundation
import FoundationToolbox
import Dependencies
import RuntimeViewerCore
import RuntimeViewerCommunication
#if os(macOS)
import RuntimeViewerHelperClient
import RuntimeViewerCatalystExtensions
#endif

// Everything in the engine manager that belongs to one platform is in this
// file: the live value of each seam the manager reaches the platform through,
// and the macOS-only reconnection of injected processes over XPC. The
// manager's other files compile the same on every platform.
//
// On the Mac the seams reach the embedded XPC services, the privileged helper
// daemon and Mac Catalyst. Everywhere else they say "this platform has none
// of it": no Mac Catalyst to launch, files read in this process, no process
// to probe for the shared cache it maps.

extension RuntimeEngineManager.MacCatalystLaunching {
    /// The app embeds the Mac Catalyst service and reaches it directly; a
    /// process whose bundle does not — the standalone CLI host — opens the
    /// helper application through the daemon. See `MacCatalystRuntimeService`.
    /// `nil` off the Mac, where there is no Mac Catalyst.
    static let live: RuntimeEngineManager.MacCatalystLaunching? = {
        #if os(macOS)
        if let credential = MacCatalystRuntimeService.embeddedServiceCredential {
            return Self(
                makeConnectedEngine: {
                    let runtimeEngine = RuntimeEngine(source: .macCatalystClient)
                    try await runtimeEngine.connect(credential: credential)
                    return runtimeEngine
                },
                helperApplication: nil
            )
        }
        return Self(
            makeConnectedEngine: {
                let runtimeEngine = RuntimeEngine(source: .macCatalystClient)
                try await runtimeEngine.connect()
                return runtimeEngine
            },
            helperApplication: HelperApplication(
                launch: {
                    @Dependency(\.runtimeHelperClient) var runtimeHelperClient
                    try await runtimeHelperClient.launchMacCatalystHelper()
                },
                terminate: {
                    @Dependency(\.runtimeHelperClient) var runtimeHelperClient
                    await runtimeHelperClient.terminateMacCatalystHelper()
                },
                handshakeTimeout: 15,
                daemonBecameAvailable: {
                    @Dependency(\.helperServiceManager) var helperServiceManager
                    return helperServiceManager.daemonAvailabilityPublisher
                }
            )
        )
        #else
        return nil
        #endif
    }()
}

extension RuntimeEngineManager.FileReading {
    /// In an instance of the app's file service on the Mac — `nil`, and so
    /// unavailable, in a process that embeds none — and in this process
    /// everywhere else, where no XPC service can be embedded.
    static var live: Self {
        #if os(macOS)
        .inFileService { file in try RuntimeFileService.credential(for: file) }
        #else
        .inThisProcess
        #endif
    }
}

extension RuntimeSharedCacheEligibility {
    /// Probes the process itself: whether it runs translated, and its
    /// environment. Off the Mac no process can be probed, and nothing is
    /// shared.
    static let live: RuntimeSharedCacheEligibility = {
        #if os(macOS)
        return RuntimeSharedCacheEligibility(
            isTranslated: { ProcessTranslationProbe.isTranslated(processIdentifier: $0) },
            environment: { ProcessEnvironmentProbe.environment(ofProcess: $0) }
        )
        #else
        return .unavailable
        #endif
    }()
}

#if os(macOS)
/// Reconnects to already-injected non-sandboxed apps by fetching their
/// registered XPC endpoints from the Mach Service daemon. A type of its own,
/// not an extension of the manager, because `#log` logs through the type it
/// is written in, and the manager's logger is private to its own file.
@Loggable
@MainActor
enum InjectedXPCEngineReconnection {
    static func reconnect(in manager: RuntimeEngineManager) async {
        @Dependency(\.runtimeInjectClient) var runtimeInjectClient
        do {
            let injectedEndpoints = try await runtimeInjectClient.fetchAllInjectedEndpoints()
            guard !injectedEndpoints.isEmpty else {
                #log(.info, "No injected endpoints to reconnect")
                return
            }
            #log(.info, "Found \(injectedEndpoints.count) injected endpoint(s) to reconnect")

            for injectedEndpointInfo in injectedEndpoints {
                do {
                    let runtimeEngine = RuntimeEngine(
                        source: .remote(
                            name: injectedEndpointInfo.appName,
                            identifier: .init(rawValue: "\(injectedEndpointInfo.pid)"),
                            role: .client
                        )
                    )
                    try await runtimeEngine.connect(credential: .xpcServer(injectedEndpointInfo.endpoint))
                    #log(.info, "Reconnected to injected app: \(injectedEndpointInfo.appName, privacy: .public) (PID: \(injectedEndpointInfo.pid))")
                    manager.attachedRuntimeEngines.append(runtimeEngine)
                    manager.observeRuntimeEngineState(runtimeEngine)
                } catch {
                    #log(.error, "Failed to reconnect to injected app \(injectedEndpointInfo.appName, privacy: .public) (PID: \(injectedEndpointInfo.pid)): \(error, privacy: .public)")
                    // Clean up stale endpoint
                    try? await runtimeInjectClient.removeInjectedEndpoint(pid: injectedEndpointInfo.pid)
                }
            }
            manager.rebuildSections()
            await manager.waitForSharedCacheOwnersUpdate()
        } catch {
            #log(.error, "Failed to fetch injected endpoints: \(error, privacy: .public)")
        }
    }
}
#endif
