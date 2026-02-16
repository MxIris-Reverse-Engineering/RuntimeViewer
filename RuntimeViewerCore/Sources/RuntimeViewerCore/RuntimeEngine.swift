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

@Loggable
public actor RuntimeEngine {
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

    public private(set) var loadedImagePaths: [String] = []
    
    @Published
    public private(set) var imageNodes: [RuntimeImageNode] = []

    public var reloadDataPublisher: some Publisher<Void, Never> {
        reloadDataSubject.eraseToAnyPublisher()
    }

    private let reloadDataSubject = PassthroughSubject<Void, Never>()

    private let objcSectionFactory: RuntimeObjCSectionFactory

    private let swiftSectionFactory: RuntimeSwiftSectionFactory

    private let communicator = RuntimeCommunicator()

    /// The connection to the sender or receiver
    private var connection: RuntimeConnection?

    public init(source: RuntimeSource) {
        self.source = source
        self.objcSectionFactory = .init()
        self.swiftSectionFactory = .init()
        #log(.info, "Initializing RuntimeEngine with source: \(String(describing: source), privacy: .public)")
    }
    
    public func connect() async throws {
        if let role = source.remoteRole {
            stateSubject.send(.connecting)

            switch role {
            case .server:
                #log(.info, "Starting as server")
                self.connection = try await communicator.connect(to: source) { connection in
                    self.connection = connection
                    self.setupMessageHandlerForServer()
                    self.observeConnectionState(connection)
                }
                #log(.info, "Server connection established")
                await observeRuntime()
                stateSubject.send(.connected)
            case .client:
                #log(.info, "Starting as client")
                self.connection = try await communicator.connect(to: source) { connection in
                    self.connection = connection
                    self.setupMessageHandlerForClient()
                    self.observeConnectionState(connection)
                }
                #log(.info, "Client connected successfully")
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
        #log(.info, "RuntimeEngine stopped")
    }

    private func setupMessageHandlerForServer() {
        #log(.debug, "Setting up server message handlers")
        setMessageHandlerBinding(forName: .isImageLoaded, of: self) { $0.isImageLoaded(path:) }
        setMessageHandlerBinding(forName: .loadImage, of: self) { $0.loadImage(at:) }
        setMessageHandlerBinding(forName: .imageNameOfClassName, of: self) { $0.imageName(ofObjectName:) }

        setMessageHandlerBinding(forName: .runtimeObjectsInImage, of: self) { $0.objects(in:) }
        setMessageHandlerBinding(forName: .runtimeInterfaceForRuntimeObjectInImageWithOptions, of: self) { $0.interface(for:) }
        setMessageHandlerBinding(forName: .runtimeObjectHierarchy, of: self) { $0.hierarchy(for:) }
        #log(.debug, "Server message handlers setup complete")
    }

    private func setupMessageHandlerForClient() {
        #log(.debug, "Setting up client message handlers")
        setMessageHandlerBinding(forName: .imageList) { $0.imageList = $1 }
        setMessageHandlerBinding(forName: .imageNodes) { $0.imageNodes = $1 }
        setMessageHandlerBinding(forName: .reloadData) { $0.reloadDataSubject.send() }
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

    private func _objects(in image: String) async throws -> [RuntimeObject] {
        #log(.debug, "Getting objects in image: \(image, privacy: .public)")
        let image = DyldUtilities.patchImagePathForDyld(image)
        let objcObjects = try await objcSectionFactory.section(for: image).allObjects()
        let swiftObjects = try await swiftSectionFactory.section(for: image).allObjects()
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
            _ = try await objcSectionFactory.section(for: path)
            _ = try await swiftSectionFactory.section(for: path)
            reloadData(isReloadImageNodes: false)
            loadedImagePaths.append(path)
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
                return try await objcSectionFactory.existingSection(for: object.imagePath)?.classHierarchy(for: object) ?? []
            case .swift:
                return try await swiftSectionFactory.existingSection(for: object.imagePath)?.classHierarchy(for: object) ?? []
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

// MARK: - Export

extension RuntimeEngine {
    public enum RuntimeExportError: Error {
        case interfaceGenerationFailed(RuntimeObject)
    }

    public func exportInterface(
        for object: RuntimeObject,
        options: RuntimeObjectInterface.GenerationOptions
    ) async throws -> RuntimeInterfaceExportItem {
        guard let runtimeInterface = try await interface(for: object, options: options) else {
            throw RuntimeExportError.interfaceGenerationFailed(object)
        }
        return RuntimeInterfaceExportItem(
            object: object,
            plainText: runtimeInterface.interfaceString.string,
            suggestedFileName: object.exportFileName
        )
    }

    public func exportInterfaces(
        in imagePath: String,
        options: RuntimeObjectInterface.GenerationOptions,
        reporter: RuntimeInterfaceExportReporter
    ) async throws -> [RuntimeInterfaceExportItem] {
        let startTime = CFAbsoluteTimeGetCurrent()

        reporter.send(.phaseStarted(.preparing))
        let allObjects = try await objects(in: imagePath)
        reporter.send(.phaseCompleted(.preparing))

        reporter.send(.phaseStarted(.exporting))
        var results: [RuntimeInterfaceExportItem] = []
        var succeeded = 0
        var failed = 0
        var objcCount = 0
        var swiftCount = 0
        let total = allObjects.count

        for (index, object) in allObjects.enumerated() {
            reporter.send(.objectStarted(object, current: index + 1, total: total))
            do {
                guard let runtimeInterface = try await interface(for: object, options: options) else {
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

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let result = RuntimeInterfaceExportResult(
            succeeded: succeeded,
            failed: failed,
            totalDuration: duration,
            objcCount: objcCount,
            swiftCount: swiftCount
        )
        reporter.send(.completed(result))
        reporter.finish()
        return results
    }
}
