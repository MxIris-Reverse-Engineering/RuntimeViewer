#if canImport(Network)

import Foundation
import Combine
import RuntimeViewerCommunication

/// Wraps a ``RuntimeEngine`` and exposes it over a direct-TCP server connection.
///
/// ``RuntimeEngineProxyServer`` starts a TCP listener (auto-assigned port) and
/// registers request handlers that forward each command to the underlying engine.
/// It also subscribes to the engine's Combine publishers to relay push data
/// (image nodes, image list, reload notifications) to the connected client.
///
/// ## Usage
///
/// ```swift
/// let proxy = RuntimeEngineProxyServer(engine: engine, identifier: "MyProxy")
/// try await proxy.start()
/// print("Proxy available at \(proxy.host):\(proxy.port)")
/// ```
public actor RuntimeEngineProxyServer {
    public let engine: RuntimeEngine

    private let communicator = RuntimeCommunicator()
    private var connection: RuntimeConnection?
    private var subscriptions: Set<AnyCancellable> = []
    private let identifier: String

    public private(set) var port: UInt16 = 0
    public private(set) var host: String = ""

    public init(engine: RuntimeEngine, identifier: String) {
        self.engine = engine
        self.identifier = identifier
    }

    /// Starts the proxy server on an auto-assigned TCP port.
    ///
    /// After this method returns, ``host`` and ``port`` are populated with the
    /// actual listening address.
    public func start() async throws {
        let source = RuntimeSource.directTCP(
            name: identifier,
            host: nil,
            port: 0,
            role: .server
        )
        connection = try await communicator.connect(to: source, waitForConnection: false)
        if let info = connection?.connectionInfo {
            host = info.host
            port = info.port
        }
        // Register handlers after a client actually connects,
        // because underlyingConnection is nil until then.
        connection?.statePublisher
            .sink { [weak self] state in
                guard let self else { return }
                if state == .connected {
                    Task {
                        await self.setupRequestHandlers()
                        await self.setupPushRelay()
                    }
                }
            }
            .store(in: &subscriptions)
    }

    /// Stops the proxy server and releases all resources.
    public func stop() {
        connection?.stop()
        subscriptions.removeAll()
    }

    // MARK: - Request Handlers

    private func setupRequestHandlers() {
        guard let connection else { return }

        connection.setMessageHandler(name: RuntimeEngine.CommandNames.isImageLoaded.commandName) {
            [engine] (path: String) -> Bool in
            try await engine.isImageLoaded(path: path)
        }

        connection.setMessageHandler(name: RuntimeEngine.CommandNames.runtimeObjectsInImage.commandName) {
            [engine] (image: String) -> [RuntimeObject] in
            try await engine.objects(in: image)
        }

        connection.setMessageHandler(name: RuntimeEngine.CommandNames.runtimeInterfaceForRuntimeObjectInImageWithOptions.commandName) {
            [engine] (request: RuntimeEngine.InterfaceRequest) -> RuntimeObjectInterface? in
            try await engine.interface(for: request.object, options: request.options)
        }

        connection.setMessageHandler(name: RuntimeEngine.CommandNames.runtimeObjectHierarchy.commandName) {
            [engine] (object: RuntimeObject) -> [String] in
            try await engine.hierarchy(for: object)
        }

        connection.setMessageHandler(name: RuntimeEngine.CommandNames.loadImage.commandName) {
            [engine] (path: String) in
            try await engine.loadImage(at: path)
        }

        connection.setMessageHandler(name: RuntimeEngine.CommandNames.imageNameOfClassName.commandName) {
            [engine] (name: RuntimeObject) -> String? in
            try await engine.imageName(ofObjectName: name)
        }

        connection.setMessageHandler(name: RuntimeEngine.CommandNames.memberAddresses.commandName) {
            [engine] (request: RuntimeEngine.MemberAddressesRequest) -> [RuntimeMemberAddress] in
            try await engine.memberAddresses(for: request.object, memberName: request.memberName)
        }
    }

    // MARK: - Push Relay

    private func setupPushRelay() {
        guard let connection else { return }

        engine.imageNodesPublisher
            .dropFirst()
            .sink { imageNodes in
                Task {
                    try? await connection.sendMessage(
                        name: RuntimeEngine.CommandNames.imageNodes.commandName,
                        request: imageNodes
                    )
                }
            }
            .store(in: &subscriptions)

        engine.reloadDataPublisher
            .sink { [weak self] in
                guard let self else { return }
                Task {
                    let imageList = await self.engine.imageList
                    try? await connection.sendMessage(
                        name: RuntimeEngine.CommandNames.imageList.commandName,
                        request: imageList
                    )
                    try? await connection.sendMessage(
                        name: RuntimeEngine.CommandNames.reloadData.commandName
                    )
                }
            }
            .store(in: &subscriptions)
    }
}

#endif
