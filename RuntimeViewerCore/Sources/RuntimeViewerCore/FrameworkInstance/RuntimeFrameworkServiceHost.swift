#if os(macOS)

import Foundation
public import FoundationToolbox
public import RuntimeViewerCommunication

/// The framework service's whole job: serve an engine over this process's
/// images, into which the app loads the frameworks the user picked.
///
/// The service plugin builds one of these around
/// `RuntimeXPCServiceListenerConnection.embeddedService()` and calls
/// `activate()`. Nothing happens before the app attaches: its first `hello`
/// says which instance this is (``RuntimeFrameworkService``), and before that
/// `hello` is answered this host makes the engine — noting the images already
/// loaded, RuntimeViewer's own, which its sidebar leaves out — and installs
/// its commands through a `RuntimeLocalServiceHost`. Tests build the same type
/// around an anonymous listener.
@Loggable(.private)
public final class RuntimeFrameworkServiceHost: @unchecked Sendable {
    private let connection: RuntimeXPCServiceListenerConnection

    @Mutex
    private var serviceHost: RuntimeLocalServiceHost?

    public init(connection: RuntimeXPCServiceListenerConnection) {
        self.connection = connection
        connection.setLaunchHandler { [weak self] payload in
            guard let self else { return }
            try await self.launch(with: payload)
        }
    }

    /// The engine over this process's images, once the first `hello` came.
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
        let instance = try RuntimeFrameworkService.instance(fromLaunchPayload: payload)
        let engine = RuntimeEngine(
            servingFrameworkInstance: instance,
            engineID: "framework-service.\(ProcessInfo.processInfo.processIdentifier)"
        )
        let serviceHost = RuntimeLocalServiceHost(engine: engine, connection: connection)
        try await serviceHost.start()
        self.serviceHost = serviceHost
        #log(.info, "Framework service serving \(instance.name, privacy: .public)")
    }
}

#endif
