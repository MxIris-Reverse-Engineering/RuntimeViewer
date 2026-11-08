#if os(macOS)

import Foundation
import Combine
public import FoundationToolbox
public import RuntimeViewerCommunication

/// An in-process engine served on an XPC service's listener: the local
/// service's whole job, with its `.local` engine.
///
/// The local service builds one of these around an engine and a
/// `RuntimeXPCServiceListenerConnection.embeddedService()`, calls `start()`,
/// then `activate()` — in `RuntimeViewerServicePlugin`'s `runLocalService()`,
/// which the service's executable loads. The Mac Catalyst service does the
/// same from the plugin's `runCatalystService()`: its job is this one, run in
/// a Catalyst process. The offline service builds one once the app's
/// first `hello` named the file, around an engine reading it
/// (`RuntimeOfflineServiceHost`). Tests build the same type around an
/// anonymous listener and connect a client engine to its endpoint, so the
/// whole path — hello, initial data, forwarded requests, pushes — runs inside
/// one process.
///
/// A client attaching is the listener reporting `.connected`, and that is
/// when the host pushes the engine's current image list and image nodes.
/// After the service was relaunched the client's `hello` lands on a fresh
/// process, so what it gets is an empty slate — which is the truth, and
/// what walks the app's document back to the image list.
@Loggable(.private)
public final class RuntimeLocalServiceHost {
    public let engine: RuntimeEngine

    private let connection: RuntimeXPCServiceListenerConnection

    private let server: RuntimeEngineConnectionServer

    private var attachSubscription: AnyCancellable?

    public init(engine: RuntimeEngine, connection: RuntimeXPCServiceListenerConnection) {
        self.engine = engine
        self.connection = connection
        self.server = RuntimeEngineConnectionServer(engine: engine, connection: connection, label: "RuntimeLocalService")
    }

    /// Connects the engine and installs every handler and relay.
    ///
    /// Everything is wired before a client is answered, because a request
    /// that reaches the service ahead of its handler fails: the local runtime
    /// service starts its host before the listener activates, the offline
    /// service inside its launch handler, before the first `hello` is
    /// answered. The relays are installed once and stay: the listener keeps
    /// one peer slot, and a push with nobody attached is simply dropped.
    public func start() async throws {
        if !engine.state.isReady {
            try await engine.connect()
        }
        await server.registerRequestHandlers()
        await server.installPushRelay()
        let server = self.server
        attachSubscription = connection.statePublisher
            .filter(\.isConnected)
            .sink { _ in
                Task { await server.sendInitialData() }
            }
        let imageCount = await engine.imageList.count
        #log(.info, "Local service host ready: \(imageCount, privacy: .public) images")
    }

    /// Starts accepting clients. For the embedded service this is `xpc_main`
    /// and does not return.
    public func activate() {
        connection.activate()
    }

    public func stop() async {
        attachSubscription = nil
        await server.stop()
        connection.stop()
        await engine.stop()
    }
}

#endif
