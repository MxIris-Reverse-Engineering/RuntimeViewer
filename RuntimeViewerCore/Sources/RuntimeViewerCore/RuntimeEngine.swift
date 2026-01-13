import Logging
import MachOKit
import FoundationToolbox
import RuntimeViewerObjC
public import Foundation
public import Combine
public import RuntimeViewerCommunication
//public import Version

public actor RuntimeEngine {
    fileprivate enum CommandNames: String, CaseIterable {
        case classList
        case protocolList
        case imageList
        case protocolToImage
        case imageToProtocols
        case loadImage
        case serverLaunched
        case isImageLoaded
        case classNamesInImage
        case patchImagePathForDyld
        case semanticStringForRuntimeObjectWithOptions
        case imageNodes
        case runtimeObjectHierarchy
        case runtimeObjectInfo
        case imageNameOfClassName
        case observeRuntime
        case interfaceForRuntimeObjectInImageWithOptions
        case namesOfKindInImage
        case namesInImage
        case reloadData

        var commandName: String { "com.RuntimeViewer.RuntimeViewerCore.RuntimeEngine.\(rawValue)" }
    }
    
    public static let shared = RuntimeEngine()

    public nonisolated let source: RuntimeSource
    
    public private(set) var imageList: [String] = []

    @Published
    public private(set) var imageNodes: [RuntimeImageNode] = []
    
    public var reloadDataPublisher: some Publisher<Void, Never> {
        reloadDataSubject.eraseToAnyPublisher()
    }
    
    private let reloadDataSubject = PassthroughSubject<Void, Never>()
    
    private var imageToObjCSection: [String: RuntimeObjCSection] = [:]

    private var imageToSwiftSection: [String: RuntimeSwiftSection] = [:]

    private static let logger = Logger(label: "com.RuntimeViewer.RuntimeViewerCore.RuntimeEngine")

    private var logger: Logger { Self.logger }

    private let communicator = RuntimeCommunicator()

    /// The connection to the sender or receiver
    private var connection: RuntimeConnection?

//    public private(set) var helperVersion: VersionModule.Version?
    
    public init() {
        self.source = .local
        
        Task {
            try await observeRuntime()
        }
    }

    #if os(macOS)
    public static func macCatalystClient() async throws -> Self {
        try await Self(source: .macCatalystClient)
    }

    public static func macCatalystServer() async throws -> Self {
        try await Self(source: .macCatalystServer)
    }
    #endif

    public init(source: RuntimeSource) async throws {
        self.source = source
        
        if let role = source.remoteRole {
            switch role {
            case .server:
                self.connection = try await communicator.connect(to: source) { connection in
                    self.connection = connection
                    self.setupMessageHandlerForServer()
                }

                try await observeRuntime()
            case .client:
                self.connection = try await communicator.connect(to: source) { connection in
                    self.connection = connection
                    self.setupMessageHandlerForClient()
                }
                logger.debug("Client connected")
            }
        } else {
            try await observeRuntime()
        }
    }

    private func setupMessageHandlerForServer() {
        setMessageHandlerBinding(forName: .isImageLoaded, of: self) { $0.isImageLoaded(path:) }
        setMessageHandlerBinding(forName: .loadImage, of: self) { $0.loadImage(at:) }
        setMessageHandlerBinding(forName: .imageNameOfClassName, of: self) { $0.imageName(ofObjectName:) }

        setMessageHandlerBinding(forName: .namesInImage, of: self) { $0.objects(in:) }
        setMessageHandlerBinding(forName: .interfaceForRuntimeObjectInImageWithOptions, of: self) { $0.interface(for:) }
        setMessageHandlerBinding(forName: .runtimeObjectHierarchy, of: self) { $0.hierarchy(for:) }
    }

    private func setupMessageHandlerForClient() {
        setMessageHandlerBinding(forName: .imageList) { $0.imageList = $1 }
        setMessageHandlerBinding(forName: .imageNodes) { $0.imageNodes = $1 }
        setMessageHandlerBinding(forName: .reloadData) { $0.reloadDataSubject.send() }
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable>(forName name: CommandNames, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Void)) {
        guard let connection else {
            logger.warning("Connection is nil when setting message handler for \(name.commandName)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [unowned object] (request: Request) in
            try await function(object)(request)
        }
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable, Response: Codable>(forName name: CommandNames, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Response)) {
        guard let connection else {
            logger.warning("Connection is nil when setting message handler for \(name.commandName)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [unowned object] (request: Request) -> Response in
            let result = try await function(object)(request)
            return result
        }
    }

    private func setMessageHandlerBinding<Response: Codable>(forName name: CommandNames, perform: @escaping (isolated RuntimeEngine, Response) async throws -> Void) {
        guard let connection else {
            logger.warning("Connection is nil when setting message handler for \(name.commandName)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [weak self] (response: Response) in
            guard let self else { return }
            try await perform(self, response)
        }
    }

    private func setMessageHandlerBinding(forName name: CommandNames, perform: @escaping (isolated RuntimeEngine) async throws -> Void) {
        guard let connection else {
            logger.warning("Connection is nil when setting message handler for \(name.commandName)")
            return
        }
        connection.setMessageHandler(name: name.commandName) { [weak self] in
            guard let self else { return }
            try await perform(self)
        }
    }

    public func reloadData(isReloadImageNodes: Bool) async {
        logger.debug("Start reload")
        imageList = DyldUtilities.imageNames()
        if isReloadImageNodes {
            imageNodes = [DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode]
        }
        logger.debug("End reload")
        sendRemoteDataIfNeeded(isReloadImageNodes: isReloadImageNodes)
    }

    private func observeRuntime() async throws {
        imageList = DyldUtilities.imageNames()
        
        await Task.detached {
            await self.setImageNodes([DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode])
        }.value

        sendRemoteDataIfNeeded(isReloadImageNodes: true)
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
                reloadDataSubject.send()
                return
            }
            try await connection.sendMessage(name: .imageList, request: imageList)
            if isReloadImageNodes {
                try await connection.sendMessage(name: .imageNodes, request: imageNodes)
            }
            try await connection.sendMessage(name: .reloadData)
        }
    }
    
    private func _objects(in image: String) async throws -> [RuntimeObject] {
        let image = DyldUtilities.patchImagePathForDyld(image)
        let objcObjects = try await _objcSection(for: image).allObjects()
        let swiftObjects = try await _swiftSection(for: image).allObjects()
        return objcObjects + swiftObjects
    }

    private func _interface(for name: RuntimeObject, options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface? {
        switch name.kind {
        case .swift:
            let swiftSection = imageToSwiftSection[name.imagePath]
            try await swiftSection?.updateConfiguration(using: options.swiftInterfaceOptions)
            return try? await swiftSection?.interface(for: name)
        case .c, .objc:
            let objcSection = imageToObjCSection[name.imagePath]
            if let interface = try? await objcSection?.interface(for: name, using: options.objcHeaderOptions) {
                return interface
            } else {
                switch name.kind {
                case .objc(.type(let kind)):
                    switch kind {
                    case .class:
                        return try? await _objcSection(forName: .class(name.name))?.interface(for: name, using: options.objcHeaderOptions)
                    case .protocol:
                        return try? await _objcSection(forName: .protocol(name.name))?.interface(for: name, using: options.objcHeaderOptions)
                    }
                default:
                    break
                }
            }
            return nil
        }
    }

    private func _objcSection(for imagePath: String) async throws -> RuntimeObjCSection {
        if let objcSection = imageToObjCSection[imagePath] {
            return objcSection
        } else {
            let objcSection = try await RuntimeObjCSection(imagePath: imagePath)
            imageToObjCSection[imagePath] = objcSection
            return objcSection
        }
    }
    
    private func _objcSection(forName name: RuntimeObjCName) async -> RuntimeObjCSection? {
        do {
            guard let machO = MachOImage.image(forName: name) else { return nil }
            
            if let existObjCSection = imageToObjCSection[machO.imagePath] {
                return existObjCSection
            }
            
            let objcSection = try await RuntimeObjCSection(machO: machO)
            imageToObjCSection[machO.imagePath] = objcSection
            return objcSection
        } catch {
            logger.error("\(error)")
            return nil
        }
    }
    
    private func _swiftSection(for imagePath: String) async throws -> RuntimeSwiftSection {
        if let swiftSection = imageToSwiftSection[imagePath] {
            return swiftSection
        } else {
            let swiftSection = try await RuntimeSwiftSection(imagePath: imagePath)
            imageToSwiftSection[imagePath] = swiftSection
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
            await reloadData(isReloadImageNodes: false)
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
            return try await senderConnection.sendMessage(name: .interfaceForRuntimeObjectInImageWithOptions, request: InterfaceRequest(object: request.object, options: request.options))
        }
    }

    public func objects(in image: String) async throws -> [RuntimeObject] {
        try await request {
            try await _objects(in: image)
        } remote: {
            return try await $0.sendMessage(name: .namesInImage, request: image)
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
