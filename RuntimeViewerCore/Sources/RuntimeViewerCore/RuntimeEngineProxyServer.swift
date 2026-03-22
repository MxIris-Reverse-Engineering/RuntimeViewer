#if canImport(Network)

import Foundation
import Combine
import RuntimeViewerCommunication

private func proxyLog(_ msg: String) { NSLog("[PROXY] %@", msg) }

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

    public func start() async throws {
        let source = RuntimeSource.directTCP(
            name: identifier,
            host: nil,
            port: 0,
            role: .server
        )
        proxyLog("[PROXY \(self.identifier)] starting...")
        connection = try await communicator.connect(to: source, waitForConnection: false)
        if let info = connection?.connectionInfo {
            host = info.host
            port = info.port
        }
        proxyLog("[PROXY \(self.identifier)] listening on \(self.host):\(self.port)")

        let id = identifier
        connection?.statePublisher
            .sink { [weak self] state in
                guard let self else { return }
                proxyLog("[PROXY \(id)] connection state: \(String(describing: state))")
                if state == .connected {
                    Task {
                        proxyLog("[PROXY \(id)] client connected, setting up handlers...")
                        await self.setupRequestHandlers()
                        proxyLog("[PROXY \(id)] request handlers registered")
                        await self.setupPushRelay()
                        proxyLog("[PROXY \(id)] push relay set up, sending initial data...")
                        await self.sendInitialData()
                        proxyLog("[PROXY \(id)] initial data sent")
                    }
                }
            }
            .store(in: &subscriptions)
    }

    private func sendInitialData() async {
        guard let connection else {
            proxyLog("[PROXY \(self.identifier)] sendInitialData: connection is nil!")
            return
        }
        let imageList = await engine.imageList
        let imageNodes = await engine.imageNodes
        proxyLog("[PROXY \(self.identifier)] sendInitialData: imageList=\(imageList.count), imageNodes=\(imageNodes.count)")
        do {
            try await connection.sendMessage(
                name: RuntimeEngine.CommandNames.imageList.commandName,
                request: imageList
            )
            proxyLog("[PROXY \(self.identifier)] sent imageList OK")
        } catch {
            proxyLog("[PROXY \(self.identifier)] failed to send imageList: \(error)")
        }
        do {
            try await connection.sendMessage(
                name: RuntimeEngine.CommandNames.imageNodes.commandName,
                request: imageNodes
            )
            proxyLog("[PROXY \(self.identifier)] sent imageNodes OK")
        } catch {
            proxyLog("[PROXY \(self.identifier)] failed to send imageNodes: \(error)")
        }
        do {
            try await connection.sendMessage(
                name: RuntimeEngine.CommandNames.reloadData.commandName
            )
            proxyLog("[PROXY \(self.identifier)] sent reloadData OK")
        } catch {
            proxyLog("[PROXY \(self.identifier)] failed to send reloadData: \(error)")
        }
    }

    public func stop() {
        proxyLog("[PROXY \(self.identifier)] stopping")
        connection?.stop()
        subscriptions.removeAll()
    }

    // MARK: - Request Handlers

    private func setupRequestHandlers() {
        guard let connection else {
            proxyLog("[PROXY \(self.identifier)] setupRequestHandlers: connection is nil!")
            return
        }

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
        proxyLog("[PROXY \(self.identifier)] all handlers registered")
    }

    // MARK: - Push Relay

    private func setupPushRelay() {
        guard let connection else {
            proxyLog("[PROXY \(self.identifier)] setupPushRelay: connection is nil!")
            return
        }

        let id = identifier
        engine.imageNodesPublisher
            .dropFirst()
            .sink { imageNodes in
                proxyLog("[PROXY \(id)] relaying imageNodes (\(imageNodes.count) nodes)")
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
                proxyLog("[PROXY \(id)] relaying reloadData")
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
