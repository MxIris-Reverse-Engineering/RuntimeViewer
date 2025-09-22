import Logging
import Combine
import Foundation
import ClassDumpRuntime
import FoundationToolbox
import RuntimeViewerCommunication

public actor RuntimeEngine {
    public static let shared = RuntimeEngine()

    private static let logger = Logger(label: "RuntimeEngine")

    @Published private var classList: [String] = []

    @Published private var protocolList: [String] = []

    @Published private var protocolToImage: [String: String] = [:]

    @Published private var imageToProtocols: [String: [String]] = [:]

    @Published public private(set) var imageList: [String] = []

    @Published public private(set) var imageNodes: [RuntimeNamedNode] = []

    @Published public private(set) var imageToSwiftSections: [String: RuntimeSwiftSections] = [:]

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
                print("Client connected")
            }
        } else {
            try await observeRuntime()
        }
    }

    private func setupMessageHandlerForServer() {
        setMessageHandlerBinding(forName: .isImageLoaded, of: self) { $0.isImageLoaded(path:) }
        setMessageHandlerBinding(forName: .loadImage, of: self) { $0.loadImage(at:) }
        setMessageHandlerBinding(forName: .classNamesInImage, of: self) { $0.classNamesIn(image:) }
        setMessageHandlerBinding(forName: .patchImagePathForDyld, of: self) { $0.patchImagePathForDyld(_:) }
        setMessageHandlerBinding(forName: .runtimeObjectHierarchy, of: self) { $0.runtimeObjectHierarchy(_:) }
        setMessageHandlerBinding(forName: .imageNameOfClassName, of: self) { $0.imageName(ofClass:) }
        setMessageHandlerBinding(forName: .namesOfKindInImage, of: self) { $0.names(for:) }
        setMessageHandlerBinding(forName: .interfaceForRuntimeObjectInImageWithOptions, of: self) { $0.interface(for:) }
    }

    private func setupMessageHandlerForClient() {
        setMessageHandlerBinding(forName: .classList) { $0.classList = $1 }
        setMessageHandlerBinding(forName: .protocolList) { $0.protocolList = $1 }
        setMessageHandlerBinding(forName: .imageList) { $0.imageList = $1 }
        setMessageHandlerBinding(forName: .protocolToImage) { $0.protocolToImage = $1 }
        setMessageHandlerBinding(forName: .imageToProtocols) { $0.imageToProtocols = $1 }
        setMessageHandlerBinding(forName: .imageNodes) { $0.imageNodes = $1 }
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

    public func reloadData() {
        Self.logger.debug("Start reload")
        classList = ObjCRuntime.classNames()
        protocolList = ObjCRuntime.protocolNames()
        imageList = DyldUtilities.imageNames()
//        imageNodes = [DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode]
        Self.logger.debug("End reload")
        sendRemoteDataIfNeeded()
    }

    private func observeRuntime() async throws {
        classList = ObjCRuntime.classNames()
        protocolList = ObjCRuntime.protocolNames()
        imageList = DyldUtilities.imageNames()
        let (protocolToImage, imageToProtocols) = ObjCRuntime.protocolImageTrackingFor(
            protocolList: protocolList, protocolToImage: [:], imageToProtocols: [:]
        ) ?? ([:], [:])
        self.protocolToImage = protocolToImage
        self.imageToProtocols = imageToProtocols

        await Task.detached {
            await self.setImageNodes([DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode])
        }.value

        shouldReload
            .debounce(for: .milliseconds(15), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                Task {
                    await self.reloadData()
                }
            }
            .store(in: &subscriptions)

        $protocolList
            .combineLatest($protocolToImage, $imageToProtocols)
            .sink { [weak self] in
                guard let self else { return }
                guard let (protocolToImage, imageToProtocols) = ObjCRuntime.protocolImageTrackingFor(
                    protocolList: $0, protocolToImage: $1, imageToProtocols: $2
                ) else { return }
                Task {
                    await self.setProtocolToImage(protocolToImage)
                    await self.setImageToProtocols(imageToProtocols)
                }
            }
            .store(in: &subscriptions)

//        observeDyldRegister()
        sendRemoteDataIfNeeded()
    }

    private func setImageNodes(_ imageNodes: [RuntimeNamedNode]) async {
        self.imageNodes = imageNodes
    }

    private func setSwiftSection(_ section: RuntimeSwiftSections, forImage image: String) async {
        imageToSwiftSections[image] = section
    }

    private func setImageToProtocols(_ imageToProtocols: [String: [String]]) async {
        self.imageToProtocols = imageToProtocols
    }

    private func setProtocolToImage(_ protocolToImage: [String: String]) async {
        self.protocolToImage = protocolToImage
    }

    private func sendRemoteDataIfNeeded() {
        guard let role = source.remoteRole, role.isServer, let connection else { return }
        Task {
            try await connection.sendMessage(name: .classList, request: self.classList)
            try await connection.sendMessage(name: .protocolList, request: self.protocolList)
            try await connection.sendMessage(name: .imageList, request: self.imageList)
            try await connection.sendMessage(name: .imageNodes, request: self.imageNodes)
            try await connection.sendMessage(name: .protocolToImage, request: self.protocolToImage)
            try await connection.sendMessage(name: .imageToProtocols, request: self.imageToProtocols)
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

    private func _interface(for name: RuntimeObjectName, options: RuntimeObjectInterface.GenerationOptions) -> RuntimeObjectInterface? {
        switch name.kind {
        case .swift:
            return try? imageToSwiftSections[name.imagePath]?.interface(for: name, options: options.swiftDemangleOptions)
        case .objc(let kindOfObjC):
            switch kindOfObjC {
            case .class:
                guard let interfaceString = RuntimeObjectType.class(named: name.name).semanticString(for: options.objcHeaderOptions)?.semanticString else { return nil }
                return RuntimeObjectInterface(name: name, interfaceString: interfaceString)
            case .protocol:
                guard let interfaceString = RuntimeObjectType.protocol(named: name.name).semanticString(for: options.objcHeaderOptions)?.semanticString else { return nil }
                return RuntimeObjectInterface(name: name, interfaceString: interfaceString)
            }
        default:
            fatalError()
        }
    }

    private func _names(of kind: RuntimeObjectKind, in image: String) async throws -> [RuntimeObjectName] {
        let image = DyldUtilities.patchImagePathForDyld(image)
        switch kind {
        case .c:
            fatalError()
        case .objc(let kindOfObjC):
            switch kindOfObjC {
            case .class:
                return ObjCRuntime.classNamesIn(image: image).map { .init(name: $0, kind: .objc(.class), imagePath: image) }
            case .protocol:
                return (imageToProtocols[DyldUtilities.patchImagePathForDyld(image)] ?? []).map { .init(name: $0, kind: .objc(.protocol), imagePath: image) }
            }
        case .swift(let kindOfSwift):
            let swiftSections = try await getOrCreateSwiftSections(for: image)
            switch kindOfSwift {
            case .enum:
                return (try? swiftSections.enumNames()) ?? []
            case .struct:
                return (try? swiftSections.structNames()) ?? []
            case .class:
                return (try? swiftSections.classNames()) ?? []
            case .protocol:
                return (try? swiftSections.protocolNames()) ?? []
            }
        }
    }

    private func getOrCreateSwiftSections(for imagePath: String) async throws -> RuntimeSwiftSections {
        if let swiftSections = imageToSwiftSections[imagePath] {
            return swiftSections
        } else {
            let swiftSections = try RuntimeSwiftSections(imagePath: imagePath)
            await setSwiftSection(swiftSections, forImage: imagePath)
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
            let section = try RuntimeSwiftSections(imagePath: path)
            await setSwiftSection(section, forImage: path)
            reloadData()
            reloadDataSubject.send(())
        } remote: {
            try await $0.sendMessage(name: .loadImage, request: path)
            reloadDataSubject.send(())
        }
    }

    public func classNamesIn(image: String) async throws -> [String] {
        try await request {
            ObjCRuntime.classNamesIn(image: image)
        } remote: {
            return try await $0.sendMessage(name: .classNamesInImage, request: image)
        }
    }

    public func patchImagePathForDyld(_ imagePath: String) async throws -> String {
        try await request {
            DyldUtilities.patchImagePathForDyld(imagePath)
        } remote: {
            return try await $0.sendMessage(name: .patchImagePathForDyld, request: imagePath)
        }
    }

    public func imageName(ofClass className: String) async throws -> String? {
        try await request {
            ObjCRuntime.imageName(ofClass: className)
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
            _interface(for: request.name, options: request.options)
        } remote: { senderConnection in
            return try await senderConnection.sendMessage(name: .interfaceForRuntimeObjectInImageWithOptions, request: InterfaceRequest(name: request.name, options: request.options))
        }
    }

    private struct NamesRequest: Codable {
        let kind: RuntimeObjectKind
        let image: String
    }

    public func names(of kind: RuntimeObjectKind, in image: String) async throws -> [RuntimeObjectName] {
        return try await names(for: .init(kind: kind, image: image))
    }

    private func names(for request: NamesRequest) async throws -> [RuntimeObjectName] {
        try await self.request {
            try await _names(of: request.kind, in: request.image)
        } remote: {
            return try await $0.sendMessage(name: .namesOfKindInImage, request: NamesRequest(kind: request.kind, image: request.image))
        }
    }

    private struct SemanticStringRequest: Codable {
        let runtimeObject: RuntimeObjectType
        let options: CDGenerationOptions
    }

    public func semanticString(for runtimeObject: RuntimeObjectType, options: CDGenerationOptions) async throws -> CDSemanticString? {
        try await request {
            runtimeObject.semanticString(for: options)
        } remote: {
            let semanticStringData: Data? = try await $0.sendMessage(name: .semanticStringForRuntimeObjectWithOptions, request: SemanticStringRequest(runtimeObject: runtimeObject, options: options))
            return try semanticStringData.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: CDSemanticString.self, from: $0) }
        }
    }

    public func runtimeObjectHierarchy(_ runtimeObject: RuntimeObjectType) async throws -> [String] {
        try await request {
            runtimeObject.hierarchy()
        } remote: {
            return try await $0.sendMessage(name: .runtimeObjectHierarchy, request: runtimeObject)
        }
    }

    public func runtimeObjectInfo(_ runtimeObject: RuntimeObjectType) async throws -> RuntimeObjectInfo {
        try await request {
            try runtimeObject.info()
        } remote: {
            return try await $0.sendMessage(name: .runtimeObjectInfo, request: runtimeObject)
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
