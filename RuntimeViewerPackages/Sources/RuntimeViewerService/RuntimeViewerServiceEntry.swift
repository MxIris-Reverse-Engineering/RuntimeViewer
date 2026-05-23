#if os(macOS)

import Foundation
import HelperCommunication
import HelperServer
import HelperService
import RuntimeViewerCommunication

/// Daemon entry point.
///
/// The `com.JH.RuntimeViewerService` (Debug) and `com.mxiris.runtimeviewer.service`
/// (Release) executables both invoke `RuntimeViewerServiceEntry.runDaemon()` from
/// their `main.swift`. The function spawns a `HelperServer` (which auto-mounts
/// `MainService` for the endpoint registry / version reconcile / ping handlers),
/// activates the listener, then blocks on the current run loop forever. The
/// helper-service business logic lives in four `HelperService` actors:
/// `ApplicationsService`, `InjectedEndpointRegistryService`, `InjectionService`,
/// `FilesService`.
public enum RuntimeViewerServiceEntry {
    public static func runDaemon() -> Never {
        Task {
            do {
                let server = try await HelperServer(
                    serverType: .machService(name: RuntimeViewerMachServiceName),
                    version: RuntimeViewerServiceVersion,
                    services: [
                        ApplicationsService(),
                        InjectedEndpointRegistryService(),
                        InjectionService(),
                        FilesService(),
                    ]
                )
                await server.activate()
                // Hold a strong reference to `server` for the lifetime of the
                // process. The daemon is torn down by an explicit `unregister()`
                // from the host or by a kill signal — never by returning from
                // this Task.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
                    // Intentionally never resumed.
                }
                _ = server
            } catch {
                fatalError("Failed to start RuntimeViewer helper service: \(error)")
            }
        }
        RunLoop.current.run()
        fatalError("RunLoop unexpectedly returned in RuntimeViewer helper service")
    }
}

#endif
