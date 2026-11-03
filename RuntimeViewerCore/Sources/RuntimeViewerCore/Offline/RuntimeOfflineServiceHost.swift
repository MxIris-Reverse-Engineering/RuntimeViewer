#if os(macOS)

import Foundation
public import FoundationToolbox
public import RuntimeViewerCommunication

/// The offline service's whole job: read the file the app names, and serve it.
///
/// The service's `main.swift` builds one of these around
/// `RuntimeXPCServiceListenerConnection.embeddedService()` and calls
/// `activate()`. Nothing is read before the app attaches: its first `hello`
/// carries the file (``RuntimeOfflineService``), and before that `hello` is
/// answered this host opens the file, connects an engine reading it and
/// installs the engine's commands through a `RuntimeLocalRuntimeServiceHost`
/// — the same host the local runtime service runs, here started after the
/// listener activated rather than before. A file that cannot be read fails
/// the `hello`, and with it the app's connect, carrying the reason. Tests
/// build the same type around an anonymous listener.
///
/// One instance serves one file for its whole life: a later `hello` waits
/// for the same launch.
@Loggable(.private)
public final class RuntimeOfflineServiceHost: @unchecked Sendable {
    private let connection: RuntimeXPCServiceListenerConnection

    @Mutex
    private var serviceHost: RuntimeLocalRuntimeServiceHost?

    public init(connection: RuntimeXPCServiceListenerConnection) {
        self.connection = connection
        connection.setLaunchHandler { [weak self] payload in
            guard let self else { return }
            try await self.launch(with: payload)
        }
    }

    /// The engine reading the file, once the first `hello` named it.
    public var engine: RuntimeEngine? {
        serviceHost?.engine
    }

    /// Starts accepting the app. For the embedded service this is `xpc_main`
    /// and does not return.
    public func activate() {
        connection.activate()
    }

    public func stop() async {
        if let serviceHost {
            await serviceHost.stop()
        } else {
            connection.stop()
        }
    }

    private func launch(with payload: Data) async throws {
        let file = try RuntimeOfflineService.file(fromLaunchPayload: payload)
        let engine = try RuntimeEngine(reading: file, engineID: "offline-service.\(ProcessInfo.processInfo.processIdentifier)")
        let serviceHost = RuntimeLocalRuntimeServiceHost(engine: engine, connection: connection)
        try await serviceHost.start()
        self.serviceHost = serviceHost
        #log(.info, "Offline service reading \(file.displayName, privacy: .public)")
    }
}

#endif
