import MachOKit
public import FoundationToolbox
import RuntimeViewerCoreObjC
public import Foundation
public import Combine
public import RuntimeViewerCommunication

// public import Version

// MARK: - RuntimeEngine.State

extension RuntimeEngine {
    /// Represents the current state of the RuntimeEngine.
    public enum State: Sendable, Equatable {
        /// The engine is being initialized.
        case initializing

        /// The engine is running locally without a remote connection.
        case localOnly

        /// The engine is attempting to connect to a remote source.
        case connecting

        /// The engine is connected to a remote source.
        case connected

        /// The engine has been disconnected from the remote source.
        case disconnected(error: RuntimeConnectionError?)

        /// Returns `true` if the engine is ready to process requests.
        public var isReady: Bool {
            switch self {
            case .localOnly,
                 .connected:
                return true
            case .initializing,
                 .connecting,
                 .disconnected:
                return false
            }
        }
    }
}

// MARK: - RuntimeEngine

@Loggable(.private)
public actor RuntimeEngine {
    enum CommandNames: String, CaseIterable {
        case imageList
        case imageNodes
        case loadImage
        case isImageLoaded
        case isImageIndexed
        case mainExecutablePath
        case loadImageForBackgroundIndexing
        case patchImagePathForDyld
        case runtimeObjectHierarchy
        case runtimeObjectInfo
        case imageNameOfClassName
        case observeRuntime
        case runtimeInterfaceForRuntimeObjectInImageWithOptions
        case runtimeObjectsOfKindInImage
        case runtimeObjectsInImage
        case reloadData
        case imageDidLoad
        case memberAddresses
        case engineList
        case engineListChanged
        case objectsLoadingProgress

        var commandName: String {
            "com.RuntimeViewer.RuntimeViewerCore.RuntimeEngine.\(rawValue)"
        }
    }

    public static let local: RuntimeEngine = {
        let runtimeEngine = RuntimeEngine(source: .local)
        Task {
            try await runtimeEngine.connect()
        }
        return runtimeEngine
    }()

    /// Callback for serving engine list requests. Set by RuntimeEngineManager.
    public static var engineListProvider: (() async -> [RemoteEngineDescriptor])?

    /// Callback for handling engine list change notifications. Set by RuntimeEngineManager.
    public static var engineListChangedHandler: (([RemoteEngineDescriptor], RuntimeEngine) async -> Void)?

    /// Globally unique identifier for this engine instance.
    public nonisolated let engineID: String

    public nonisolated let source: RuntimeSource

    public nonisolated let hostInfo: HostInfo

    public nonisolated let originChain: [String]

    /// Whether this engine should load and push runtime data to connected clients.
    /// Set to `false` for management-only engines (e.g. Bonjour server) that only handle engine list operations.
    public nonisolated let pushesRuntimeData: Bool

    // MARK: - State Management

    private var connectionStateCancellable: AnyCancellable?

    /// Flag indicating that message handlers need to be re-registered on next connection.
    /// Set to `true` when a server connection disconnects, so that reconnection
    /// triggers handler re-registration and data push.
    private var needsReregistrationOnConnect = false

    private nonisolated let stateSubject = CurrentValueSubject<State, Never>(.initializing)
    
    /// Publisher that emits engine state changes.
    public nonisolated var statePublisher: some Publisher<State, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    /// The current engine state.
    public nonisolated var state: State {
        stateSubject.value
    }

    // MARK: - Data Properties

    public private(set) var imageList: [String] = []

    public internal(set) var loadedImagePaths: Set<String> = []

    private nonisolated let imageNodesSubject = CurrentValueSubject<[RuntimeImageNode], Never>([])

    public var imageNodes: [RuntimeImageNode] {
        get { imageNodesSubject.value }
        set { imageNodesSubject.send(newValue) }
    }

    /// Publisher that emits image node changes. Accessible from any isolation context.
    public nonisolated var imageNodesPublisher: some Publisher<[RuntimeImageNode], Never> {
        imageNodesSubject.eraseToAnyPublisher()
    }

    public nonisolated var reloadDataPublisher: some Publisher<Void, Never> {
        reloadDataSubject.eraseToAnyPublisher()
    }

    private nonisolated let reloadDataSubject = PassthroughSubject<Void, Never>()

    /// Publisher that emits the image path each time `loadImage(at:)` succeeds.
    ///
    /// Fires on the local arm immediately after the image has been loaded and
    /// its ObjC/Swift sections cached. On a client engine, it fires when the
    /// server forwards an `.imageDidLoad` event (handled by
    /// `setupMessageHandlerForClient`).
    ///
    /// Marked `nonisolated` so subscribers (including Combine sinks in tests
    /// and downstream coordinators) can attach without an actor hop.
    public nonisolated var imageDidLoadPublisher: some Publisher<String, Never> {
        imageDidLoadSubject.eraseToAnyPublisher()
    }

    private nonisolated let imageDidLoadSubject = PassthroughSubject<String, Never>()

    private nonisolated let objectsLoadingProgressSubject = PassthroughSubject<RuntimeObjectsLoadingProgress, Never>()

    let objcSectionFactory: RuntimeObjCSectionFactory

    let swiftSectionFactory: RuntimeSwiftSectionFactory

    private let communicator = RuntimeCommunicator()

    /// The connection to the sender or receiver
    private var connection: RuntimeConnection?

    /// The XPC listener endpoint of this engine's connection, if applicable.
    /// Set after `connect()` succeeds for XPC-based connections (macOS only).
    /// Used by injected apps to register their endpoint with the Mach Service
    /// for Host reconnection. Stored as `any Sendable` to avoid platform-specific
    /// types in the actor interface; cast to `SwiftyXPC.XPCEndpoint` on macOS.
    public private(set) var xpcListenerEndpoint: (any Sendable)?

    /// Coordinator for background indexing batches that load and index images
    /// without blocking the main runtime data flow. Created at the end of
    /// `init` so it can capture `self` after all other stored properties are
    /// initialized.
    public private(set) var backgroundIndexingManager: RuntimeBackgroundIndexingManager!

    public init(
        source: RuntimeSource,
        engineID: String = UUID().uuidString,
        hostInfo: HostInfo = HostInfo(
            hostID: RuntimeNetworkBonjour.localInstanceID,
            hostName: RuntimeNetworkBonjour.localHostName
        ),
        originChain: [String] = [RuntimeNetworkBonjour.localInstanceID],
        pushesRuntimeData: Bool = true
    ) {
        self.engineID = engineID
        self.source = source
        self.hostInfo = hostInfo
        self.originChain = originChain
        self.pushesRuntimeData = pushesRuntimeData
        self.objcSectionFactory = .init()
        self.swiftSectionFactory = .init()
        #log(.info, "Initializing RuntimeEngine with source: \(String(describing: source), privacy: .public)")
        self.backgroundIndexingManager = RuntimeBackgroundIndexingManager(engine: self)
    }

    public func connect(bonjourEndpoint: RuntimeNetworkEndpoint? = nil, xpcServerEndpoint: (any Sendable)? = nil) async throws {
        if let role = source.remoteRole {
            stateSubject.send(.connecting)

            switch role {
            case .server:
                #log(.info, "Starting as server")
                connection = try await communicator.connect(to: source, bonjourEndpoint: bonjourEndpoint) { connection in
                    self.connection = connection
                    self.setupMessageHandlerForServer()
                    self.observeConnectionState(connection)
                }
                #log(.info, "Server connection established")
                #if os(macOS)
                if let xpcEndpointProvider = connection as? XPCListenerEndpointProviding {
                    xpcListenerEndpoint = xpcEndpointProvider.xpcListenerEndpoint
                }
                #endif
                if pushesRuntimeData {
                    await observeRuntime()
                }
                stateSubject.send(.connected)
            case .client:
                #log(.info, "Starting as client for source: \(String(describing: self.source), privacy: .public)")
                connection = try await communicator.connect(to: source, bonjourEndpoint: bonjourEndpoint, xpcServerEndpoint: xpcServerEndpoint) { connection in
                    #log(.debug, "[EngineMirroring] client connection modifier called for \(String(describing: self.source), privacy: .public), connection state: \(String(describing: connection.state), privacy: .public)")
                    self.connection = connection
                    self.setupMessageHandlerForClient()
                    self.observeConnectionState(connection)
                }
                #log(.info, "Client connected successfully to \(String(describing: self.source), privacy: .public)")
                stateSubject.send(.connected)
            }
        } else {
            #log(.debug, "No remote role, observing local runtime")
            await observeRuntime()
            stateSubject.send(.localOnly)
        }
    }

    /// Observes the connection state and updates the engine state accordingly.
    private func observeConnectionState(_ connection: RuntimeConnection) {
        connectionStateCancellable = connection.statePublisher
            .sink { [weak self] state in
                guard let self else { return }
                Task {
                    await self.handleConnectionStateChange(state)
                }
            }
    }

    /// Handles connection state changes and updates the engine state.
    private func handleConnectionStateChange(_ connectionState: RuntimeConnectionState) {
        switch connectionState {
        case .connecting:
            #log(.info, "Connection state -> connecting (source: \(String(describing: self.source), privacy: .public))")
            stateSubject.send(.connecting)
        case .connected:
            #log(.info, "Connection state -> connected (source: \(String(describing: self.source), privacy: .public))")
            stateSubject.send(.connected)
            // Re-register handlers and push data when server reconnects to a new client
            if needsReregistrationOnConnect, source.remoteRole == .server {
                needsReregistrationOnConnect = false
                #log(.info, "Server reconnected, re-registering handlers and pushing data")
                setupMessageHandlerForServer()
                if pushesRuntimeData {
                    Task { await self.observeRuntime() }
                }
            }
        case .disconnected(let error):
            if let error {
                #log(.error, "Connection state -> disconnected with error: \(error.localizedDescription, privacy: .public) (source: \(String(describing: self.source), privacy: .public))")
            } else {
                #log(.info, "Connection state -> disconnected (source: \(String(describing: self.source), privacy: .public))")
            }
            stateSubject.send(.disconnected(error: error))
            if source.remoteRole == .server {
                needsReregistrationOnConnect = true
            }
        }
    }

    /// Stops the engine and its connection.
    public func stop() {
        connectionStateCancellable?.cancel()
        connectionStateCancellable = nil
        connection?.stop()
        stateSubject.send(.disconnected(error: nil))
        #log(.info, "RuntimeEngine stopped")
    }

    private func setupMessageHandlerForServer() {
        #log(.debug, "Setting up server message handlers")
        setMessageHandlerBinding(forName: .isImageLoaded, of: self) { $0.isImageLoaded(path:) }
        setMessageHandlerBinding(forName: .isImageIndexed, of: self) { $0.isImageIndexed(path:) }
        setMessageHandlerBinding(forName: .mainExecutablePath) { engine -> String in
            try await engine.mainExecutablePath()
        }
        setMessageHandlerBinding(forName: .loadImage, of: self) { $0.loadImage(at:) }
        setMessageHandlerBinding(forName: .loadImageForBackgroundIndexing, of: self) { $0.loadImageForBackgroundIndexing(at:) }
        setMessageHandlerBinding(forName: .imageNameOfClassName, of: self) { $0.imageName(ofObjectName:) }

        connection?.setMessageHandler(name: CommandNames.runtimeObjectsInImage.commandName) { [weak self] (imagePath: String) -> [RuntimeObject] in
            guard let self else { throw RequestError.senderConnectionIsLose }
            return try await self._serverObjectsWithProgress(in: imagePath)
        }
        setMessageHandlerBinding(forName: .runtimeInterfaceForRuntimeObjectInImageWithOptions, of: self) { $0.interface(for:) }
        setMessageHandlerBinding(forName: .runtimeObjectHierarchy, of: self) { $0.hierarchy(for:) }
        setMessageHandlerBinding(forName: .memberAddresses, of: self) { $0.memberAddresses(for:) }
        setMessageHandlerBinding(forName: .engineList) { _ -> [RemoteEngineDescriptor] in
            #log(.debug, "[EngineMirroring] engineList handler called, provider set: \(RuntimeEngine.engineListProvider != nil, privacy: .public)")
            let result = await RuntimeEngine.engineListProvider?() ?? []
            #log(.debug, "[EngineMirroring] engineList handler returning \(result.count, privacy: .public) descriptors")
            return result
        }
        #log(.debug, "Server message handlers setup complete")
    }

    private func setupMessageHandlerForClient() {
        #log(.debug, "Setting up client message handlers for source: \(String(describing: self.source), privacy: .public)")
        setMessageHandlerBinding(forName: .imageList) { $0.imageList = $1 }
        setMessageHandlerBinding(forName: .imageNodes) { $0.imageNodes = $1 }
        setMessageHandlerBinding(forName: .reloadData) { $0.reloadDataSubject.send() }
        setMessageHandlerBinding(forName: .imageDidLoad) { (engine: RuntimeEngine, path: String) in
            engine.imageDidLoadSubject.send(path)
        }
        setMessageHandlerBinding(forName: .objectsLoadingProgress) { $0.objectsLoadingProgressSubject.send($1) }
        setMessageHandlerBinding(forName: .engineListChanged) { (engine: RuntimeEngine, descriptors: [RemoteEngineDescriptor]) in
            #log(.debug, "[EngineMirroring] engineListChanged received: \(descriptors.count, privacy: .public) descriptors, handler set: \(RuntimeEngine.engineListChangedHandler != nil, privacy: .public)")
            await RuntimeEngine.engineListChangedHandler?(descriptors, engine)
        }
        #log(.debug, "Client message handlers setup complete")
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable>(forName name: CommandNames, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Void)) {
        guard let connection else {
            #log(.default, "Connection is nil when setting message handler for \(name.commandName, privacy: .public)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [unowned object] (request: Request) in
            try await function(object)(request)
        }
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable, Response: Codable>(forName name: CommandNames, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Response)) {
        guard let connection else {
            #log(.default, "Connection is nil when setting message handler for \(name.commandName, privacy: .public)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [unowned object] (request: Request) -> Response in
            let result = try await function(object)(request)
            return result
        }
    }

    private func setMessageHandlerBinding<Response: Codable>(forName name: CommandNames, perform: @escaping (isolated RuntimeEngine, Response) async throws -> Void) {
        guard let connection else {
            #log(.default, "Connection is nil when setting message handler for \(name.commandName, privacy: .public)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [weak self] (response: Response) in
            guard let self else { return }
            try await perform(self, response)
        }
    }

    private func setMessageHandlerBinding(forName name: CommandNames, perform: @escaping (isolated RuntimeEngine) async throws -> Void) {
        guard let connection else {
            #log(.default, "Connection is nil when setting message handler for \(name.commandName, privacy: .public)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [weak self] in
            guard let self else { return }
            try await perform(self)
        }
    }

    /// Overload for commands with no request body but a response.
    private func setMessageHandlerBinding<Response: Codable>(
        forName name: CommandNames,
        respond: @escaping (isolated RuntimeEngine) async throws -> Response
    ) {
        guard let connection else {
            #log(.default, "Connection is nil when setting message handler for \(name.commandName, privacy: .public)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [weak self] () -> Response in
            guard let self else { throw RequestError.senderConnectionIsLose }
            return try await respond(self)
        }
    }

    public func reloadData(isReloadImageNodes: Bool) {
        #log(.info, "Reloading data, isReloadImageNodes=\(isReloadImageNodes, privacy: .public)")
        imageList = DyldUtilities.imageNames()
        #log(.debug, "Loaded \(self.imageList.count, privacy: .public) images")
        if isReloadImageNodes {
            imageNodes = [DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode]
            #log(.debug, "Reloaded image nodes")
        }
        sendRemoteDataIfNeeded(isReloadImageNodes: isReloadImageNodes)
        #log(.info, "Data reload complete")
    }

    private func observeRuntime() async {
        #log(.info, "Starting runtime observation")
        imageList = DyldUtilities.imageNames()
        #log(.debug, "Initial image list contains \(self.imageList.count, privacy: .public) images")

        await Task.detached {
            await self.setImageNodes([DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode])
        }.value
        #log(.debug, "Image nodes initialized")

        sendRemoteDataIfNeeded(isReloadImageNodes: true)
        #log(.info, "Runtime observation started")
    }

    private func setImageNodes(_ imageNodes: [RuntimeImageNode]) {
        self.imageNodes = imageNodes
    }

    private func sendRemoteDataIfNeeded(isReloadImageNodes: Bool) {
        Task {
            guard let role = source.remoteRole, role.isServer, let connection else {
                #log(.debug, "No remote connection, sending local reload notification")
                reloadDataSubject.send()
                return
            }
            #log(.debug, "Sending remote data to client")
            try await connection.sendMessage(name: .imageList, request: imageList)
            if isReloadImageNodes {
                try await connection.sendMessage(name: .imageNodes, request: imageNodes)
            }
            try await connection.sendMessage(name: .reloadData)
            #log(.debug, "Remote data sent successfully")
        }
    }

    /// Forwards an `imageDidLoad` event to the connected client when this
    /// engine is acting as a server. On a local-only engine the local subject
    /// has already been signaled by the caller, so this is a no-op.
    private func sendRemoteImageDidLoadIfNeeded(path: String) {
        guard let role = source.remoteRole, role.isServer, let connection else { return }
        Task {
            try await connection.sendMessage(name: .imageDidLoad, request: path)
            #log(.debug, "Remote imageDidLoad sent for path: \(path, privacy: .public)")
        }
    }

    private func _objects(in image: String) async throws -> [RuntimeObject] {
        #log(.debug, "Getting objects in image: \(image, privacy: .public)")
        let image = DyldUtilities.patchImagePathForDyld(image)
        let (isObjCSectionExisted, objcSection) = try await objcSectionFactory.section(for: image)
        let objcObjects = try await objcSection.allObjects()
        let (isSwiftSectionExisted, swiftSection) = try await swiftSectionFactory.section(for: image)
        let swiftObjects = try await swiftSection.allObjects()
        if !isObjCSectionExisted || !isSwiftSectionExisted {
            loadedImagePaths.insert(image)
        }
        #log(.debug, "Found \(objcObjects.count, privacy: .public) ObjC and \(swiftObjects.count, privacy: .public) Swift objects")
        return objcObjects + swiftObjects
    }

    private func _interface(for name: RuntimeObject, options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface? {
        let rawInterface: RuntimeObjectInterface?

        switch name.kind {
        case .swift:
            let swiftSection = await swiftSectionFactory.existingSection(for: name.imagePath)
            try await swiftSection?.updateConfiguration(using: options.swiftInterfaceOptions, transformer: options.transformer.swift)
            return try? await swiftSection?.interface(for: name)
        case .c,
             .objc:
            let objcSection = await objcSectionFactory.existingSection(for: name.imagePath)
            let objcTransformer = options.transformer.objc
            if let interface = try? await objcSection?.interface(for: name, using: options.objcHeaderOptions, transformer: objcTransformer) {
                return interface
            } else {
                switch name.kind {
                case .objc(.type(let kind)):
                    switch kind {
                    case .class:
                        return try? await objcSectionFactory.section(for: .class(name.name))?.interface(for: name, using: options.objcHeaderOptions, transformer: objcTransformer)
                    case .protocol:
                        return try? await objcSectionFactory.section(for: .protocol(name.name))?.interface(for: name, using: options.objcHeaderOptions, transformer: objcTransformer)
                    }
                default:
                    rawInterface = nil
                }
            }
        }

        return rawInterface
    }
}

// MARK: - Requests

extension RuntimeEngine {
    enum RequestError: Error {
        case senderConnectionIsLose
    }

    func request<T>(local: () async throws -> T, remote: (_ senderConnection: RuntimeConnection) async throws -> T) async throws -> T {
        if let remoteRole = source.remoteRole, remoteRole.isClient {
            guard let connection else { throw RequestError.senderConnectionIsLose }
            return try await remote(connection)
        } else {
            return try await local()
        }
    }

    public func isImageLoaded(path: String) async throws -> Bool {
        try await request {
            imageList.contains(DyldUtilities.patchImagePathForDyld(path))
        } remote: {
            return try await $0.sendMessage(name: .isImageLoaded, request: path)
        }
    }

    public func loadImage(at path: String) async throws {
        try await request {
            try DyldUtilities.loadImage(at: path)
            _ = try await objcSectionFactory.section(for: path)
            _ = try await swiftSectionFactory.section(for: path)
            reloadData(isReloadImageNodes: false)
            loadedImagePaths.insert(path)
            imageDidLoadSubject.send(path)
            sendRemoteImageDidLoadIfNeeded(path: path)
        } remote: {
            try await $0.sendMessage(name: .loadImage, request: path)
        }
    }

    public func imageName(ofObjectName name: RuntimeObject) async throws -> String? {
        try await request {
            nil
        } remote: {
            return try await $0.sendMessage(name: .imageNameOfClassName, request: name)
        }
    }

    struct InterfaceRequest: Codable {
        let object: RuntimeObject
        let options: RuntimeObjectInterface.GenerationOptions
    }

    public func interface(for object: RuntimeObject, options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface? {
        return try await interface(for: .init(object: object, options: options))
    }

    private func interface(for request: InterfaceRequest) async throws -> RuntimeObjectInterface? {
        try await self.request {
            try await _interface(for: request.object, options: request.options)
        } remote: { senderConnection in
            return try await senderConnection.sendMessage(name: .runtimeInterfaceForRuntimeObjectInImageWithOptions, request: InterfaceRequest(object: request.object, options: request.options))
        }
    }

    public func objects(in image: String) async throws -> [RuntimeObject] {
        try await request {
            try await _objects(in: image)
        } remote: {
            return try await $0.sendMessage(name: .runtimeObjectsInImage, request: image)
        }
    }

    public func objectsWithProgress(in image: String) -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Swift.Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let objects: [RuntimeObject]
                    if let remoteRole = self.source.remoteRole, remoteRole.isClient {
                        objects = try await self._remoteObjectsWithProgress(in: image, continuation: continuation)
                    } else {
                        objects = try await self._localObjectsWithProgress(in: image, continuation: continuation)
                    }
                    continuation.yield(.completed(objects))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func _localObjectsWithProgress(
        in image: String,
        continuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Swift.Error>.Continuation
    ) async throws -> [RuntimeObject] {
        #log(.debug, "Getting objects with progress in image: \(image, privacy: .public)")
        let image = DyldUtilities.patchImagePathForDyld(image)
        let (isObjCSectionExisted, objcSection) = try await objcSectionFactory.section(for: image, progressContinuation: continuation)
        let objcObjects = try await objcSection.allObjects()
        let (isSwiftSectionExisted, swiftSection) = try await swiftSectionFactory.section(for: image, progressContinuation: continuation)
        let swiftObjects = try await swiftSection.allObjects()
        if !isObjCSectionExisted || !isSwiftSectionExisted {
            loadedImagePaths.insert(image)
        }
        #log(.debug, "Found \(objcObjects.count, privacy: .public) ObjC and \(swiftObjects.count, privacy: .public) Swift objects with progress")
        return objcObjects + swiftObjects
    }

    private func _serverObjectsWithProgress(in image: String) async throws -> [RuntimeObject] {
        var result: [RuntimeObject] = []
        for try await event in objectsWithProgress(in: image) {
            switch event {
            case .progress(let progress):
                try? await connection?.sendMessage(name: .objectsLoadingProgress, request: progress)
            case .completed(let objects):
                result = objects
            }
        }
        return result
    }

    private func _remoteObjectsWithProgress(
        in image: String,
        continuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Swift.Error>.Continuation
    ) async throws -> [RuntimeObject] {
        guard let connection else { throw RequestError.senderConnectionIsLose }
        let cancellable = objectsLoadingProgressSubject.sink { progress in
            continuation.yield(RuntimeObjectsLoadingEvent.progress(progress))
        }
        defer { cancellable.cancel() }
        return try await connection.sendMessage(name: .runtimeObjectsInImage, request: image)
    }

    public func hierarchy(for object: RuntimeObject) async throws -> [String] {
        try await request { () -> [String] in
            switch object.kind {
            case .c:
                return []
            case .objc:
                return try await objcSectionFactory.existingSection(for: object.imagePath)?.classHierarchy(for: object) ?? []
            case .swift:
                return try await swiftSectionFactory.existingSection(for: object.imagePath)?.classHierarchy(for: object) ?? []
            }
        } remote: {
            return try await $0.sendMessage(name: .runtimeObjectHierarchy, request: object)
        }
    }

    struct MemberAddressesRequest: Codable {
        let object: RuntimeObject
        let memberName: String?
    }
    
    public func memberAddresses(for object: RuntimeObject, memberName: String?) async throws -> [RuntimeMemberAddress] {
        try await memberAddresses(for: .init(object: object, memberName: memberName))
    }
    
    private func memberAddresses(for request: MemberAddressesRequest) async throws -> [RuntimeMemberAddress] {
        try await self.request {
            switch request.object.kind {
            case .swift:
                return try await swiftSectionFactory.existingSection(for: request.object.imagePath)?.memberAddresses(for: request.object, memberName: request.memberName) ?? []
            case .objc:
                return try await objcSectionFactory.existingSection(for: request.object.imagePath)?.memberAddresses(for: request.object, memberName: request.memberName) ?? []
            default:
                return []
            }
        } remote: { senderConnection in
            return try await senderConnection.sendMessage(name: .memberAddresses, request: request)
        }

    }

    public func requestEngineList() async throws -> [RemoteEngineDescriptor] {
        try await request {
            []
        } remote: {
            try await $0.sendMessage(name: .engineList)
        }
    }

    public func pushEngineListChanged(_ descriptors: [RemoteEngineDescriptor]) async throws {
        let hasConnection = self.connection != nil
        let isServer = self.source.remoteRole?.isServer == true
        guard let connection, isServer else {
            #log(.debug, "[EngineMirroring] pushEngineListChanged skipped: connection=\(hasConnection, privacy: .public), isServer=\(isServer, privacy: .public)")
            return
        }
        #log(.debug, "[EngineMirroring] pushEngineListChanged sending \(descriptors.count, privacy: .public) descriptors")
        try await connection.sendMessage(name: .engineListChanged, request: descriptors)
        #log(.debug, "[EngineMirroring] pushEngineListChanged sent successfully")
    }
}

extension RuntimeConnection {
    func sendMessage(name: RuntimeEngine.CommandNames) async throws {
        return try await sendMessage(name: name.commandName)
    }

    func sendMessage<Request: Codable>(name: RuntimeEngine.CommandNames, request: Request) async throws {
        return try await sendMessage(name: name.commandName, request: request)
    }

    func sendMessage<Response: Codable>(name: RuntimeEngine.CommandNames) async throws -> Response {
        return try await sendMessage(name: name.commandName)
    }

    func sendMessage<Response: Codable>(name: RuntimeEngine.CommandNames, request: some Codable) async throws -> Response {
        return try await sendMessage(name: name.commandName, request: request)
    }
}

// MARK: - Export

extension RuntimeEngine {
    public enum RuntimeExportError: Error {
        case interfaceGenerationFailed(RuntimeObject)
    }

    public func exportInterfaces(
        with configuration: RuntimeInterfaceExportConfiguration,
        reporter: RuntimeInterfaceExportReporter
    ) async throws {
        defer { reporter.finish() }
        let startTime = CFAbsoluteTimeGetCurrent()

        reporter.send(.phaseStarted(.preparing))
        let allObjects = try await objects(in: configuration.imagePath)
        reporter.send(.phaseCompleted(.preparing))

        reporter.send(.phaseStarted(.exporting))
        var results: [RuntimeInterfaceExportItem] = []
        var succeeded = 0
        var failed = 0
        var objcCount = 0
        var swiftCount = 0
        let total = allObjects.count

        for (index, object) in allObjects.enumerated() {
            try Task.checkCancellation()
            reporter.send(.objectStarted(object, current: index + 1, total: total))
            do {
                guard let runtimeInterface = try await interface(for: object, options: configuration.generationOptions) else {
                    throw RuntimeExportError.interfaceGenerationFailed(object)
                }
                let item = RuntimeInterfaceExportItem(
                    object: object,
                    plainText: runtimeInterface.interfaceString.string,
                    suggestedFileName: object.exportFileName
                )
                results.append(item)
                succeeded += 1
                if item.isSwift { swiftCount += 1 } else { objcCount += 1 }
                reporter.send(.objectCompleted(object, runtimeInterface.interfaceString))
            } catch {
                failed += 1
                reporter.send(.objectFailed(object, error))
            }
        }
        reporter.send(.phaseCompleted(.exporting))

        reporter.send(.phaseStarted(.writing))

        var writeFailed = 0

        do {
            let objcItems = results.filter { !$0.isSwift }
            let swiftItems = results.filter { $0.isSwift }

            if !objcItems.isEmpty {
                switch configuration.objcFormat {
                case .singleFile:
                    try RuntimeInterfaceExportWriter.writeSingleFile(
                        items: objcItems,
                        to: configuration.directory,
                        imageName: configuration.imageName
                    )
                case .directory:
                    let writeResult = try RuntimeInterfaceExportWriter.writeDirectory(
                        items: objcItems,
                        to: configuration.directory
                    )
                    for (failedItem, writeError) in writeResult.failedItems {
                        reporter.send(.objectFailed(failedItem.object, writeError))
                    }
                    writeFailed += writeResult.failedItems.count
                }
            }

            if !swiftItems.isEmpty {
                switch configuration.swiftFormat {
                case .singleFile:
                    try RuntimeInterfaceExportWriter.writeSingleFile(
                        items: swiftItems,
                        to: configuration.directory,
                        imageName: configuration.imageName
                    )
                case .directory:
                    let writeResult = try RuntimeInterfaceExportWriter.writeDirectory(
                        items: swiftItems,
                        to: configuration.directory
                    )
                    for (failedItem, writeError) in writeResult.failedItems {
                        reporter.send(.objectFailed(failedItem.object, writeError))
                    }
                    writeFailed += writeResult.failedItems.count
                }
            }

            reporter.send(.phaseCompleted(.writing))
        } catch {
            reporter.send(.phaseFailed(.writing, error))
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let result = RuntimeInterfaceExportResult(
            succeeded: succeeded,
            failed: failed + writeFailed,
            totalDuration: duration,
            objcCount: objcCount,
            swiftCount: swiftCount
        )
        reporter.send(.completed(result))
    }
}
