#if os(macOS)

import Foundation
import HelperCommunication
import HelperServer
import HelperService
import ApplicationsServiceImplementation
import FilesServiceImplementation
import InjectionServiceImplementation
import InjectedEndpointRegistryServiceImplementation
import RuntimeViewerCommunication

/// Daemon entry point.
///
/// The `com.JH.RuntimeViewerService` (Debug) and `com.mxiris.runtimeviewer.service`
/// (Release) executables both invoke `RuntimeViewerService.run()` from their
/// `main.swift`. The function spawns a `HelperServer` (which auto-mounts `MainService`
/// for the endpoint registry / version reconcile / ping handlers), activates the
/// listener, then blocks on the current run loop forever. The helper-service business
/// logic lives in four `HelperService` actors provided by swift-helper-service:
/// `ApplicationsService`, `InjectedEndpointRegistryService`, `InjectionService`,
/// `FilesService`.
public enum RuntimeViewerService {
    public static func run() async throws {
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
        await server.activateAndRun()
    }
}

#endif
