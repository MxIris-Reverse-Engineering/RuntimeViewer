import Logging
import Combine
import Foundation
import ClassDumpRuntime
import FoundationToolbox
import RuntimeViewerCommunication
import RuntimeViewerObjC

public actor RuntimeEngine {
    public static let shared = RuntimeEngine()

    private static let logger = Logger(label: "RuntimeEngine")

    @Published public private(set) var imageList: [String] = []

    @Published public private(set) var imageNodes: [RuntimeImageNode] = []

    private let objcRuntime: RuntimeObjCRuntime = .init()

    @Published private var imageToObjCSection: [String: RuntimeObjCSection] = [:]
    
    @Published private var imageToSwiftSection: [String: RuntimeSwiftSection] = [:]

    private let reloadDataSubject = PassthroughSubject<Void, Never>()

    public var reloadDataPublisher: some Publisher<Void, Never> { reloadDataSubject.eraseToAnyPublisher() }

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

        var commandName: String { "com.JH.RuntimeViewerCore.RuntimeEngine.\(rawValue)" }
    }

    public nonisolated let source: RuntimeSource

    private let shouldReload = PassthroughSubject<Void, Never>()

    private let communicator = RuntimeCommunicator()

    private var subscriptions: Set<AnyCancellable> = []

    /// The connection to the sender or receiver
    private var connection: RuntimeConnection?

    public init() {
        self.source = .local
        Task {
            try await observeRuntime()
        }
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
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
                Self.logger.debug("Client connected")
            }
        } else {
            try await observeRuntime()
        }
    }

    private func setupMessageHandlerForServer() {
        setMessageHandlerBinding(forName: .isImageLoaded, of: self) { $0.isImageLoaded(path:) }
        setMessageHandlerBinding(forName: .loadImage, of: self) { $0.loadImage(at:) }
//        setMessageHandlerBinding(forName: .classNamesInImage, of: self) { $0.classNamesIn(image:) }
//        setMessageHandlerBinding(forName: .patchImagePathForDyld, of: self) { $0.patchImagePathForDyld(_:) }
        setMessageHandlerBinding(forName: .runtimeObjectHierarchy, of: self) { $0.runtimeObjectHierarchy(for:) }
        setMessageHandlerBinding(forName: .imageNameOfClassName, of: self) { $0.imageName(ofClass:) }
//        setMessageHandlerBinding(forName: .namesOfKindInImage, of: self) { $0.names(for:) }
        setMessageHandlerBinding(forName: .namesInImage, of: self) { $0.names(in:) }
        setMessageHandlerBinding(forName: .interfaceForRuntimeObjectInImageWithOptions, of: self) { $0.interface(for:) }
    }

    private func setupMessageHandlerForClient() {
//        setMessageHandlerBinding(forName: .classList) { $0.classList = $1 }
//        setMessageHandlerBinding(forName: .protocolList) { $0.protocolList = $1 }
        setMessageHandlerBinding(forName: .imageList) { $0.imageList = $1 }
//        setMessageHandlerBinding(forName: .protocolToImage) { $0.protocolToImage = $1 }
//        setMessageHandlerBinding(forName: .imageToProtocols) { $0.imageToProtocols = $1 }
        setMessageHandlerBinding(forName: .imageNodes) { $0.imageNodes = $1 }
        setMessageHandlerBinding(forName: .reloadData) { $0.reloadDataSubject.send() }
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable>(forName name: CommandNames, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Void)) {
        connection?.setMessageHandler(name: name.commandName) { [unowned object] (request: Request) in
            try await function(object)(request)
        }
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable, Response: Codable>(forName name: CommandNames, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Response)) {
        connection?.setMessageHandler(name: name.commandName) { [unowned object] (request: Request) -> Response in
            let result = try await function(object)(request)
            return result
        }
    }

    private func setMessageHandlerBinding<Response: Codable>(forName name: CommandNames, perform: @escaping (isolated RuntimeEngine, Response) async throws -> Void) {
        connection?.setMessageHandler(name: name.commandName) { [weak self] (response: Response) in
            guard let self else { return }
            try await perform(self, response)
        }
    }

    private func setMessageHandlerBinding(forName name: CommandNames, perform: @escaping (isolated RuntimeEngine) async throws -> Void) {
        connection?.setMessageHandler(name: name.commandName) { [weak self] in
            guard let self else { return }
            try await perform(self)
        }
    }

    public func reloadData(isReloadImageNodes: Bool) {
        Self.logger.debug("Start reload")
//        classList = ObjCRuntime.classNames()
//        protocolList = ObjCRuntime.protocolNames()
        objcRuntime.reloadData()
        imageList = DyldUtilities.imageNames()
        if isReloadImageNodes {
            imageNodes = [DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode]
        }
        Self.logger.debug("End reload")
        sendRemoteDataIfNeeded(isReloadImageNodes: isReloadImageNodes)
    }

    private func observeRuntime() async throws {
//        classList = ObjCRuntime.classNames()
//        protocolList = ObjCRuntime.protocolNames()
        imageList = DyldUtilities.imageNames()
        objcRuntime.reloadData()
        await Task.detached {
            await self.setImageNodes([DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode])
        }.value

        shouldReload
            .debounce(for: .milliseconds(15), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                Task {
                    await self.reloadData(isReloadImageNodes: false)
                }
            }
            .store(in: &subscriptions)

        

//        observeDyldRegister()
        sendRemoteDataIfNeeded(isReloadImageNodes: true)
    }

    private func setImageNodes(_ imageNodes: [RuntimeImageNode]) async {
        self.imageNodes = imageNodes
    }

    private func setSwiftSection(_ section: RuntimeSwiftSection, forImage image: String) async {
        imageToSwiftSection[image] = section
    }

//    private func setImageToProtocols(_ imageToProtocols: [String: [String]]) async {
//        self.imageToProtocols = imageToProtocols
//    }
//
//    private func setProtocolToImage(_ protocolToImage: [String: String]) async {
//        self.protocolToImage = protocolToImage
//    }

    private func sendRemoteDataIfNeeded(isReloadImageNodes: Bool) {
        Task {
            guard let role = source.remoteRole, role.isServer, let connection else {
                reloadDataSubject.send()
                return
            }
//            try await connection.sendMessage(name: .classList, request: classList)
//            try await connection.sendMessage(name: .protocolList, request: protocolList)
            try await connection.sendMessage(name: .imageList, request: imageList)
            if isReloadImageNodes {
                try await connection.sendMessage(name: .imageNodes, request: imageNodes)
            }
//            try await connection.sendMessage(name: .protocolToImage, request: protocolToImage)
//            try await connection.sendMessage(name: .imageToProtocols, request: imageToProtocols)
            try await connection.sendMessage(name: .reloadData)
        }
    }

    private func observeDyldRegister() {
        DyldUtilities.observeDyldRegisterEvents()

        NotificationCenter.default.publisher(for: DyldUtilities.addImageNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.shouldReload.send()
                }
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: DyldUtilities.removeImageNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.shouldReload.send()
                }
            }
            .store(in: &subscriptions)
    }

//    private func startTimingReload() {
//        Timer.publish(every: 15, on: .main, in: .default)
//            .autoconnect()
//            .sink { [weak self] _ in
//                guard let self else { return }
//
//                let classList = ObjCRuntime.classNames()
//                let protocolList = ObjCRuntime.protocolNames()
//
//                let refClassList = self.classList
//                let refProtocolList = self.protocolList
//
//                if classList != refClassList {
//                    Self.logger.error("Watchdog: classList is out-of-date")
//                    self.classList = classList
//                }
//                if protocolList != refProtocolList {
//                    Self.logger.error("Watchdog: protocolList is out-of-date")
//                    self.protocolList = protocolList
//                }
//            }
//            .store(in: &subscriptions)
//    }

    private func _interface(for name: RuntimeObjectName, options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface? {
        switch name.kind {
        case .swift:
            return try? await imageToSwiftSection[name.imagePath]?.interface(for: name, options: options.swiftDemangleOptions)
        case .objc:
            return objcRuntime.interface(for: name, options: options.objcHeaderOptions)
        default:
            fatalError()
        }
    }

    private func _objcNames(of kind: RuntimeObjectKind.ObjectiveC, in image: String) async throws -> [RuntimeObjectName] {
        let image = DyldUtilities.patchImagePathForDyld(image)
        switch kind {
        case .type(let kind):
            switch kind {
            case .class:
                return objcRuntime.classNames(in: image)
            case .protocol:
                return objcRuntime.protocolNames(in: image)
            }
        case .category:
            return []
        }
    }

    private func _names(in image: String) async throws -> [RuntimeObjectName] {
        let image = DyldUtilities.patchImagePathForDyld(image)
        let objcClasses = try await _objcNames(of: .type(.class), in: image)
        let objcProtocols = try await _objcNames(of: .type(.protocol), in: image)
        let swiftNames = try await _swiftSection(for: image).allNames()
        return objcClasses + objcProtocols + swiftNames
    }

    private func _swiftSection(for imagePath: String) async throws -> RuntimeSwiftSection {
        if let swiftSections = imageToSwiftSection[imagePath] {
            return swiftSections
        } else {
            let swiftSections = try await RuntimeSwiftSection(imagePath: imagePath)
            imageToSwiftSection[imagePath] = swiftSections
            return swiftSections
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
            _ = try await _swiftSection(for: path)
            reloadData(isReloadImageNodes: false)
        } remote: {
            try await $0.sendMessage(name: .loadImage, request: path)
        }
    }

//    public func classNamesIn(image: String) async throws -> [String] {
//        try await request {
//            ObjCRuntime.classNames(inImage: image)
//        } remote: {
//            return try await $0.sendMessage(name: .classNamesInImage, request: image)
//        }
//    }

//    public func patchImagePathForDyld(_ imagePath: String) async throws -> String {
//        try await request {
//            DyldUtilities.patchImagePathForDyld(imagePath)
//        } remote: {
//            return try await $0.sendMessage(name: .patchImagePathForDyld, request: imagePath)
//        }
//    }

    public func imageName(ofClass className: String) async throws -> String? {
        try await request {
            RuntimeObjCRuntime.imageName(ofClass: className)
        } remote: {
            return try await $0.sendMessage(name: .imageNameOfClassName, request: className)
        }
    }

    private struct InterfaceRequest: Codable {
        let name: RuntimeObjectName
        let options: RuntimeObjectInterface.GenerationOptions
    }

    public func interface(for name: RuntimeObjectName, options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface? {
        return try await interface(for: .init(name: name, options: options))
    }

    private func interface(for request: InterfaceRequest) async throws -> RuntimeObjectInterface? {
        try await self.request {
            try await _interface(for: request.name, options: request.options)
        } remote: { senderConnection in
            return try await senderConnection.sendMessage(name: .interfaceForRuntimeObjectInImageWithOptions, request: InterfaceRequest(name: request.name, options: request.options))
        }
    }

    public func names(in image: String) async throws -> [RuntimeObjectName] {
        try await request {
            try await _names(in: image)
        } remote: {
            return try await $0.sendMessage(name: .namesInImage, request: image)
        }
    }

//    private struct SemanticStringRequest: Codable {
//        let runtimeObject: RuntimeObjCRuntimeObject
//        let options: CDGenerationOptions
//    }
//
//    public func semanticString(for runtimeObject: RuntimeObjCRuntimeObject, options: CDGenerationOptions) async throws -> CDSemanticString? {
//        try await request {
//            runtimeObject.semanticString(for: options)
//        } remote: {
//            let semanticStringData: Data? = try await $0.sendMessage(name: .semanticStringForRuntimeObjectWithOptions, request: SemanticStringRequest(runtimeObject: runtimeObject, options: options))
//            return try semanticStringData.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: CDSemanticString.self, from: $0) }
//        }
//    }

    public func runtimeObjectHierarchy(for name: RuntimeObjectName) async throws -> [String] {
        try await request { () -> [String] in
            switch name.kind {
            case .c:
                return []
            case .objc:
                return objcRuntime.hierarchy(for: name)
            case .swift:
                return try await imageToSwiftSection[name.imagePath]?.classHierarchy(for: name) ?? []
            }
        } remote: {
            return try await $0.sendMessage(name: .runtimeObjectHierarchy, request: name)
        }
    }

//    public func runtimeObjectHierarchy(_ runtimeObject: RuntimeObjectType) async throws -> [String] {
//        try await request {
//            runtimeObject.hierarchy()
//        } remote: {
//            return try await $0.sendMessage(name: .runtimeObjectHierarchy, request: runtimeObject)
//        }
//    }

//    public func runtimeObjectInfo(_ runtimeObject: RuntimeObjCRuntimeObject) async throws -> RuntimeObjectInfo {
//        try await request {
//            try runtimeObject.info()
//        } remote: {
//            return try await $0.sendMessage(name: .runtimeObjectInfo, request: runtimeObject)
//        }
//    }
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
