import MachOKit
public import FoundationToolbox
import OSLog
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

public actor RuntimeEngine: Loggable {
    fileprivate enum CommandNames: String, CaseIterable {
        case imageList
        case imageNodes
        case loadImage
        case isImageLoaded
        case patchImagePathForDyld
        case runtimeObjectHierarchy
        case runtimeObjectInfo
        case imageNameOfClassName
        case observeRuntime
        case runtimeInterfaceForRuntimeObjectInImageWithOptions
        case runtimeObjectsOfKindInImage
        case runtimeObjectsInImage
        case reloadData

        var commandName: String { "com.RuntimeViewer.RuntimeViewerCore.RuntimeEngine.\(rawValue)" }
    }

    public static let shared = RuntimeEngine()

    public nonisolated let source: RuntimeSource

    // MARK: - State Management

    private nonisolated let stateSubject = CurrentValueSubject<State, Never>(.initializing)

    private var connectionStateCancellable: AnyCancellable?

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

    @Published
    public private(set) var imageNodes: [RuntimeImageNode] = []

    public var reloadDataPublisher: some Publisher<Void, Never> {
        reloadDataSubject.eraseToAnyPublisher()
    }

    private let reloadDataSubject = PassthroughSubject<Void, Never>()

    private var imageToObjCSection: [String: RuntimeObjCSection] = [:]

    private var imageToSwiftSection: [String: RuntimeSwiftSection] = [:]

    private let communicator = RuntimeCommunicator()

    /// The connection to the sender or receiver
    private var connection: RuntimeConnection?

    public init() {
        self.source = .local
        logger.info("Initializing RuntimeEngine with local source")

        Task {
            await observeRuntime()
            stateSubject.send(.localOnly)
        }
    }

    public init(source: RuntimeSource) async throws {
        self.source = source
        logger.info("Initializing RuntimeEngine with source: \(String(describing: source), privacy: .public)")

        if let role = source.remoteRole {
            stateSubject.send(.connecting)

            switch role {
            case .server:
                logger.info("Starting as server")
                self.connection = try await communicator.connect(to: source) { connection in
                    self.connection = connection
                    self.setupMessageHandlerForServer()
                    self.observeConnectionState(connection)
                }
                logger.info("Server connection established")
                await observeRuntime()
                stateSubject.send(.connected)
            case .client:
                logger.info("Starting as client")
                self.connection = try await communicator.connect(to: source) { connection in
                    self.connection = connection
                    self.setupMessageHandlerForClient()
                    self.observeConnectionState(connection)
                }
                logger.info("Client connected successfully")
                stateSubject.send(.connected)
            }
        } else {
            logger.debug("No remote role, observing local runtime")
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
            stateSubject.send(.connecting)
        case .connected:
            stateSubject.send(.connected)
        case .disconnected(let error):
            stateSubject.send(.disconnected(error: error))
        }
    }

    /// Stops the engine and its connection.
    public func stop() {
        connectionStateCancellable?.cancel()
        connectionStateCancellable = nil
        connection?.stop()
        stateSubject.send(.disconnected(error: nil))
        logger.info("RuntimeEngine stopped")
    }

    private func setupMessageHandlerForServer() {
        logger.debug("Setting up server message handlers")
        setMessageHandlerBinding(forName: .isImageLoaded, of: self) { $0.isImageLoaded(path:) }
        setMessageHandlerBinding(forName: .loadImage, of: self) { $0.loadImage(at:) }
        setMessageHandlerBinding(forName: .imageNameOfClassName, of: self) { $0.imageName(ofObjectName:) }

        setMessageHandlerBinding(forName: .runtimeObjectsInImage, of: self) { $0.objects(in:) }
        setMessageHandlerBinding(forName: .runtimeInterfaceForRuntimeObjectInImageWithOptions, of: self) { $0.interface(for:) }
        setMessageHandlerBinding(forName: .runtimeObjectHierarchy, of: self) { $0.hierarchy(for:) }
        logger.debug("Server message handlers setup complete")
    }

    private func setupMessageHandlerForClient() {
        logger.debug("Setting up client message handlers")
        setMessageHandlerBinding(forName: .imageList) { $0.imageList = $1 }
        setMessageHandlerBinding(forName: .imageNodes) { $0.imageNodes = $1 }
        setMessageHandlerBinding(forName: .reloadData) { $0.reloadDataSubject.send() }
        logger.debug("Client message handlers setup complete")
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable>(forName name: CommandNames, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Void)) {
        guard let connection else {
            logger.warning("Connection is nil when setting message handler for \(name.commandName, privacy: .public)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [unowned object] (request: Request) in
            try await function(object)(request)
        }
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable, Response: Codable>(forName name: CommandNames, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Response)) {
        guard let connection else {
            logger.warning("Connection is nil when setting message handler for \(name.commandName, privacy: .public)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [unowned object] (request: Request) -> Response in
            let result = try await function(object)(request)
            return result
        }
    }

    private func setMessageHandlerBinding<Response: Codable>(forName name: CommandNames, perform: @escaping (isolated RuntimeEngine, Response) async throws -> Void) {
        guard let connection else {
            logger.warning("Connection is nil when setting message handler for \(name.commandName, privacy: .public)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [weak self] (response: Response) in
            guard let self else { return }
            try await perform(self, response)
        }
    }

    private func setMessageHandlerBinding(forName name: CommandNames, perform: @escaping (isolated RuntimeEngine) async throws -> Void) {
        guard let connection else {
            logger.warning("Connection is nil when setting message handler for \(name.commandName, privacy: .public)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [weak self] in
            guard let self else { return }
            try await perform(self)
        }
    }

    public func reloadData(isReloadImageNodes: Bool) {
        logger.info("Reloading data, isReloadImageNodes=\(isReloadImageNodes, privacy: .public)")
        imageList = DyldUtilities.imageNames()
        logger.debug("Loaded \(self.imageList.count, privacy: .public) images")
        if isReloadImageNodes {
            imageNodes = [DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode]
            logger.debug("Reloaded image nodes")
        }
        sendRemoteDataIfNeeded(isReloadImageNodes: isReloadImageNodes)
        logger.info("Data reload complete")
    }

    private func observeRuntime() async {
        logger.info("Starting runtime observation")
        imageList = DyldUtilities.imageNames()
        logger.debug("Initial image list contains \(self.imageList.count, privacy: .public) images")

        await Task.detached {
            await self.setImageNodes([DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode])
        }.value
        logger.debug("Image nodes initialized")

        sendRemoteDataIfNeeded(isReloadImageNodes: true)
        logger.info("Runtime observation started")
    }

    private func setImageNodes(_ imageNodes: [RuntimeImageNode]) async {
        self.imageNodes = imageNodes
    }

    private func setSwiftSection(_ section: RuntimeSwiftSection, forImage image: String) async {
        imageToSwiftSection[image] = section
    }

    private func sendRemoteDataIfNeeded(isReloadImageNodes: Bool) {
        Task {
            guard let role = source.remoteRole, role.isServer, let connection else {
                logger.debug("No remote connection, sending local reload notification")
                reloadDataSubject.send()
                return
            }
            logger.debug("Sending remote data to client")
            try await connection.sendMessage(name: .imageList, request: imageList)
            if isReloadImageNodes {
                try await connection.sendMessage(name: .imageNodes, request: imageNodes)
            }
            try await connection.sendMessage(name: .reloadData)
            logger.debug("Remote data sent successfully")
        }
    }

    private func _objects(in image: String) async throws -> [RuntimeObject] {
        logger.debug("Getting objects in image: \(image, privacy: .public)")
        let image = DyldUtilities.patchImagePathForDyld(image)
        let objcObjects = try await _objcSection(for: image).allObjects()
        let swiftObjects = try await _swiftSection(for: image).allObjects()
        logger.debug("Found \(objcObjects.count, privacy: .public) ObjC and \(swiftObjects.count, privacy: .public) Swift objects")
        return objcObjects + swiftObjects
    }

    private func _interface(for name: RuntimeObject, options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface? {
        let rawInterface: RuntimeObjectInterface?

        switch name.kind {
        case .swift:
            let swiftSection = imageToSwiftSection[name.imagePath]
            try await swiftSection?.updateConfiguration(using: options.swiftInterfaceOptions)
            rawInterface = try? await swiftSection?.interface(for: name)
        case .c,
             .objc:
            let objcSection = imageToObjCSection[name.imagePath]
            if let interface = try? await objcSection?.interface(for: name, using: options.objcHeaderOptions) {
                rawInterface = interface
            } else {
                switch name.kind {
                case .objc(.type(let kind)):
                    switch kind {
                    case .class:
                        rawInterface = try? await _objcSection(forName: .class(name.name))?.interface(for: name, using: options.objcHeaderOptions)
                    case .protocol:
                        rawInterface = try? await _objcSection(forName: .protocol(name.name))?.interface(for: name, using: options.objcHeaderOptions)
                    }
                default:
                    rawInterface = nil
                }
            }
        }

        // Apply transformers if configured
        guard let rawInterface else { return nil }
        return applyTransformers(to: rawInterface, options: options)
    }

    /// Applies configured transformers to the given interface.
    private func applyTransformers(
        to interface: RuntimeObjectInterface,
        options: RuntimeObjectInterface.GenerationOptions
    ) -> RuntimeObjectInterface {
        let context = TransformContext(
            imagePath: interface.object.imagePath,
            objectName: interface.object.name
        )

        let transformedString = options.transformerConfiguration.apply(
            to: interface.interfaceString,
            context: context
        )

        return RuntimeObjectInterface(
            object: interface.object,
            interfaceString: transformedString
        )
    }

    private func _objcSection(for imagePath: String) async throws -> RuntimeObjCSection {
        if let objcSection = imageToObjCSection[imagePath] {
            logger.debug("Using cached ObjC section for: \(imagePath, privacy: .public)")
            return objcSection
        } else {
            logger.debug("Creating ObjC section for: \(imagePath, privacy: .public)")
            let objcSection = try await RuntimeObjCSection(imagePath: imagePath)
            imageToObjCSection[imagePath] = objcSection
            logger.debug("ObjC section created and cached")
            return objcSection
        }
    }

    private func _objcSection(forName name: RuntimeObjCName) async -> RuntimeObjCSection? {
        logger.debug("Looking up ObjC section for name: \(String(describing: name), privacy: .public)")
        do {
            guard let machO = MachOImage.image(forName: name) else {
                logger.debug("No MachO image found for name")
                return nil
            }

            if let existObjCSection = imageToObjCSection[machO.imagePath] {
                logger.debug("Using cached ObjC section")
                return existObjCSection
            }

            logger.debug("Creating ObjC section from MachO: \(machO.imagePath, privacy: .public)")
            let objcSection = try await RuntimeObjCSection(machO: machO)
            imageToObjCSection[machO.imagePath] = objcSection
            return objcSection
        } catch {
            logger.error("Failed to create ObjC section: \(error, privacy: .public)")
            return nil
        }
    }

    private func _swiftSection(for imagePath: String) async throws -> RuntimeSwiftSection {
        if let swiftSection = imageToSwiftSection[imagePath] {
            logger.debug("Using cached Swift section for: \(imagePath, privacy: .public)")
            return swiftSection
        } else {
            logger.debug("Creating Swift section for: \(imagePath, privacy: .public)")
            let swiftSection = try await RuntimeSwiftSection(imagePath: imagePath)
            imageToSwiftSection[imagePath] = swiftSection
            logger.debug("Swift section created and cached")
            return swiftSection
        }
    }
}

// MARK: - Requests

extension RuntimeEngine {
    enum RequestError: Error {
        case senderConnectionIsLose
    }

    private func request<T>(local: () async throws -> T, remote: (_ senderConnection: RuntimeConnection) async throws -> T) async throws -> T {
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
            _ = try await _objcSection(for: path)
            _ = try await _swiftSection(for: path)
            reloadData(isReloadImageNodes: false)
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

    private struct InterfaceRequest: Codable {
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

    public func hierarchy(for object: RuntimeObject) async throws -> [String] {
        try await request { () -> [String] in
            switch object.kind {
            case .c:
                return []
            case .objc:
                return try await imageToObjCSection[object.imagePath]?.classHierarchy(for: object) ?? []
            case .swift:
                return try await imageToSwiftSection[object.imagePath]?.classHierarchy(for: object) ?? []
            }
        } remote: {
            return try await $0.sendMessage(name: .runtimeObjectHierarchy, request: object)
        }
    }
}

extension RuntimeConnection {
    fileprivate func sendMessage(name: RuntimeEngine.CommandNames) async throws {
        return try await sendMessage(name: name.commandName)
    }

    fileprivate func sendMessage<Request: Codable>(name: RuntimeEngine.CommandNames, request: Request) async throws {
        return try await sendMessage(name: name.commandName, request: request)
    }

    fileprivate func sendMessage<Response: Codable>(name: RuntimeEngine.CommandNames) async throws -> Response {
        return try await sendMessage(name: name.commandName)
    }

    fileprivate func sendMessage<Response: Codable>(name: RuntimeEngine.CommandNames, request: some Codable) async throws -> Response {
        return try await sendMessage(name: name.commandName, request: request)
    }
}
