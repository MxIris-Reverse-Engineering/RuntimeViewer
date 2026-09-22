import Foundation
import Combine
public import FoundationToolbox
public import RuntimeViewerCommunication

/// Serves one engine on one connection.
///
/// The part `RuntimeEngineProxyServer` (a local engine shared with peers over
/// TCP) and `RuntimeLocalRuntimeServiceHost` (the in-process engine inside the
/// local-runtime XPC service) have in common: the shared command table, the
/// four pushes a client engine's `setupMessageHandlerForClient` listens for,
/// and the initial data a freshly connected client needs. Each owner decides
/// *when* to call which — a TCP server wires up per accepted client, an XPC
/// service listener needs everything in place before it activates and pushes
/// the initial data each time a client attaches.
@Loggable(.private)
public actor RuntimeEngineConnectionServer {
    public let engine: RuntimeEngine

    private let connection: any RuntimeConnection

    /// A label for the log lines, so a process serving several engines can
    /// tell their traffic apart.
    private let label: String

    /// Push-relay subscriptions. They live in their own set so
    /// `installPushRelay()` can drop the previous client's relays before wiring
    /// new ones — otherwise each reconnect would stack another relay and every
    /// data change would be sent N times.
    private var pushRelaySubscriptions: Set<AnyCancellable> = []

    public init(engine: RuntimeEngine, connection: any RuntimeConnection, label: String) {
        self.engine = engine
        self.connection = connection
        self.label = label
    }

    // MARK: - Request handlers

    /// Installs the shared command table.
    ///
    /// Every request routes through `engine.dispatch(_:)`, so an engine that is
    /// itself a client of another process forwards instead of running the
    /// local arm — see `RuntimeEngine.register(_:on:engine:)`.
    public func registerRequestHandlers() {
        RuntimeEngine.registerSharedHandlers(on: connection, engine: engine)
        #log(.info, "[\(self.label, privacy: .public)] request handlers registered")
    }

    // MARK: - Push relay

    /// Forwards the engine's data events to the connected client: image
    /// nodes, data changes (with the image list re-synced on a full reload),
    /// and `imageDidLoad`. Safe to call again for a new client; the previous
    /// client's relays are dropped first.
    public func installPushRelay() {
        pushRelaySubscriptions.removeAll()

        let connection = self.connection
        let label = self.label

        engine.imageNodesPublisher
            .dropFirst()
            .sink { imageNodes in
                #log(.info, "[\(label, privacy: .public)] relaying imageNodes (\(imageNodes.count, privacy: .public) nodes)")
                Task {
                    try? await connection.sendMessage(
                        name: RuntimeEngine.CommandNames.imageNodes.commandName,
                        request: imageNodes
                    )
                }
            }
            .store(in: &pushRelaySubscriptions)

        engine.dataChangePublisher
            .sink { [weak self] change in
                guard let self else { return }
                #log(.info, "[\(label, privacy: .public)] relaying dataChange \(String(describing: change), privacy: .public)")
                Task {
                    // Keep the client's `imageList` mirror current on full reloads;
                    // other change kinds don't affect it so we skip the extra round-trip.
                    if case .fullReload = change {
                        let imageList = await self.engine.imageList
                        try? await connection.sendMessage(
                            name: RuntimeEngine.CommandNames.imageList.commandName,
                            request: imageList
                        )
                    }
                    try? await connection.sendMessage(
                        name: RuntimeEngine.CommandNames.dataDidChange.commandName,
                        request: change
                    )
                }
            }
            .store(in: &pushRelaySubscriptions)

        engine.imageDidLoadPublisher
            .sink { path in
                #log(.debug, "[\(label, privacy: .public)] relaying imageDidLoad for \(path, privacy: .public)")
                Task {
                    try? await connection.sendMessage(
                        name: RuntimeEngine.CommandNames.imageDidLoad.commandName,
                        request: path
                    )
                }
            }
            .store(in: &pushRelaySubscriptions)
    }

    // MARK: - Initial data

    /// Pushes the current image list and image nodes, then a full-reload
    /// change, so a client that just connected — or reattached — starts from
    /// current data.
    public func sendInitialData() async {
        let imageList = await engine.imageList
        let imageNodes = engine.imageNodes
        #log(.info, "[\(self.label, privacy: .public)] sending initial data: imageList=\(imageList.count, privacy: .public), imageNodes=\(imageNodes.count, privacy: .public)")
        do {
            try await connection.sendMessage(name: RuntimeEngine.CommandNames.imageList.commandName, request: imageList)
        } catch {
            #log(.error, "[\(self.label, privacy: .public)] failed to send imageList: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try await connection.sendMessage(name: RuntimeEngine.CommandNames.imageNodes.commandName, request: imageNodes)
        } catch {
            #log(.error, "[\(self.label, privacy: .public)] failed to send imageNodes: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try await connection.sendMessage(
                name: RuntimeEngine.CommandNames.dataDidChange.commandName,
                request: RuntimeDataChange.fullReload(isReloadImageNodes: true)
            )
        } catch {
            #log(.error, "[\(self.label, privacy: .public)] failed to send dataDidChange: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Teardown

    /// Drops the push relays. The connection belongs to the owner, which
    /// stops it itself.
    public func stop() {
        pushRelaySubscriptions.removeAll()
    }
}
