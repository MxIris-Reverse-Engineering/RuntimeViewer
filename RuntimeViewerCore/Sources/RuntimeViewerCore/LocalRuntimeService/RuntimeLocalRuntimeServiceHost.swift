#if os(macOS)

public import Foundation
import Combine
public import FoundationToolbox
public import RuntimeViewerCommunication

/// The local-runtime XPC service's whole job: an in-process `.local` engine,
/// served on the service's listener.
///
/// The service's `main.swift` builds one of these around an engine and a
/// `RuntimeXPCServiceListenerConnection.embeddedService()`, calls `start()`,
/// then `activate()`. Tests build the same type around an anonymous listener
/// and connect a client engine to its endpoint, so the whole path — hello,
/// initial data, forwarded requests, pushes — runs inside one process.
///
/// A client attaching is the listener reporting `.connected`, and that is
/// when the host pushes the engine's current image list and image nodes.
/// After the service was relaunched the client's `hello` lands on a fresh
/// process, so what it gets is an empty slate — which is the truth, and
/// what walks the app's document back to the image list.
@Loggable(.private)
public final class RuntimeLocalRuntimeServiceHost {
    public let engine: RuntimeEngine

    private let connection: RuntimeXPCServiceListenerConnection

    private let server: RuntimeEngineConnectionServer

    private var attachSubscription: AnyCancellable?

    public init(engine: RuntimeEngine, connection: RuntimeXPCServiceListenerConnection) {
        self.engine = engine
        self.connection = connection
        self.server = RuntimeEngineConnectionServer(engine: engine, connection: connection, label: "LocalRuntimeService")
    }

    /// Connects the engine and installs every handler and relay.
    ///
    /// Everything is wired *before* the listener activates because SwiftyXPC
    /// copies the handlers onto each connection at accept time; a handler
    /// registered later is invisible to a client already attached. The relays
    /// are installed once and stay: the listener keeps one peer slot, and a
    /// push with nobody attached is simply dropped.
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
        #log(.info, "Local runtime service host ready: \(imageCount, privacy: .public) images")
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
