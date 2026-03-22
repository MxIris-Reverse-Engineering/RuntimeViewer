#if canImport(Network)

public import Foundation
import Combine
public import FoundationToolbox
import RuntimeViewerCommunication
#if canImport(AppKit)
import AppKit
#endif

@Loggable(.private)
public actor RuntimeEngineProxyServer {
    /// Command name for icon requests from remote clients.
    public static let iconRequestCommand = "com.RuntimeViewer.ProxyServer.requestIcon"

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
        #log(.info, "[PROXY \(self.identifier, privacy: .public)] starting...")
        connection = try await communicator.connect(to: source, waitForConnection: false)
        if let info = connection?.connectionInfo {
            host = info.host
            port = info.port
        }
        let proxyHost = self.host
        let proxyPort = self.port
        #log(.info, "[PROXY \(self.identifier, privacy: .public)] listening on \(proxyHost, privacy: .public):\(proxyPort, privacy: .public)")

        let id = self.identifier
        connection?.statePublisher
            .sink { [weak self] state in
                guard let self else { return }
                #log(.info, "[PROXY \(id, privacy: .public)] connection state: \(String(describing: state), privacy: .public)")
                if state == .connected {
                    Task {
                        #log(.info, "[PROXY \(id, privacy: .public)] client connected, setting up handlers...")
                        await self.setupRequestHandlers()
                        #log(.info, "[PROXY \(id, privacy: .public)] request handlers registered")
                        await self.setupPushRelay()
                        #log(.info, "[PROXY \(id, privacy: .public)] push relay set up, sending initial data...")
                        await self.sendInitialData()
                        #log(.info, "[PROXY \(id, privacy: .public)] initial data sent")
                    }
                }
            }
            .store(in: &subscriptions)
    }

    private func sendInitialData() async {
        guard let connection else {
            #log(.error, "[PROXY \(self.identifier, privacy: .public)] sendInitialData: connection is nil!")
            return
        }
        let imageList = await engine.imageList
        let imageNodes = await engine.imageNodes
        #log(.info, "[PROXY \(self.identifier, privacy: .public)] sendInitialData: imageList=\(imageList.count, privacy: .public), imageNodes=\(imageNodes.count, privacy: .public)")
        do {
            try await connection.sendMessage(
                name: RuntimeEngine.CommandNames.imageList.commandName,
                request: imageList
            )
            #log(.info, "[PROXY \(self.identifier, privacy: .public)] sent imageList OK")
        } catch {
            #log(.error, "[PROXY \(self.identifier, privacy: .public)] failed to send imageList: \(error, privacy: .public)")
        }
        do {
            try await connection.sendMessage(
                name: RuntimeEngine.CommandNames.imageNodes.commandName,
                request: imageNodes
            )
            #log(.info, "[PROXY \(self.identifier, privacy: .public)] sent imageNodes OK")
        } catch {
            #log(.error, "[PROXY \(self.identifier, privacy: .public)] failed to send imageNodes: \(error, privacy: .public)")
        }
        do {
            try await connection.sendMessage(
                name: RuntimeEngine.CommandNames.reloadData.commandName
            )
            #log(.info, "[PROXY \(self.identifier, privacy: .public)] sent reloadData OK")
        } catch {
            #log(.error, "[PROXY \(self.identifier, privacy: .public)] failed to send reloadData: \(error, privacy: .public)")
        }
    }

    public func stop() {
        #log(.info, "[PROXY \(self.identifier, privacy: .public)] stopping")
        connection?.stop()
        subscriptions.removeAll()
    }

    // MARK: - Request Handlers

    private func setupRequestHandlers() {
        guard let connection else {
            #log(.error, "[PROXY \(self.identifier, privacy: .public)] setupRequestHandlers: connection is nil!")
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

        #if canImport(AppKit)
        let engineSource = engine.source
        connection.setMessageHandler(name: Self.iconRequestCommand) {
            () -> Data? in
            await MainActor.run {
                Self.appIconData(for: engineSource)
            }
        }
        #endif

        #log(.info, "[PROXY \(self.identifier, privacy: .public)] all handlers registered")
    }

    // MARK: - Icon

    /// Returns the app icon PNG data for this engine's attached process, or nil.
    public func iconData() async -> Data? {
        #if canImport(AppKit)
        return await MainActor.run {
            Self.appIconData(for: engine.source)
        }
        #else
        return nil
        #endif
    }

    #if canImport(AppKit)
    @MainActor
    private static func appIconData(for source: RuntimeSource) -> Data? {
        let pidString: String?
        switch source {
        case .remote(_, let identifier, _):
            pidString = identifier.rawValue
        case .localSocket(_, let identifier, _):
            pidString = identifier.rawValue
        default:
            pidString = nil
        }
        guard let pidString, let pid = Int32(pidString) else { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }

        let icon = app.icon ?? app.bundleURL.flatMap { NSWorkspace.shared.icon(forFile: $0.path) }
        guard let icon else { return nil }
        return icon.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        }
    }
    #endif

    // MARK: - Push Relay

    private func setupPushRelay() {
        guard let connection else {
            #log(.error, "[PROXY \(self.identifier, privacy: .public)] setupPushRelay: connection is nil!")
            return
        }

        let id = self.identifier
        engine.imageNodesPublisher
            .dropFirst()
            .sink { imageNodes in
                #log(.info, "[PROXY \(id, privacy: .public)] relaying imageNodes (\(imageNodes.count, privacy: .public) nodes)")
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
                #log(.info, "[PROXY \(id, privacy: .public)] relaying reloadData")
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
