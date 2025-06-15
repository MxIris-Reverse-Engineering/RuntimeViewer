import OSLog
import Combine
import Foundation
import MachO.dyld
import ClassDumpRuntime
import FoundationToolbox
import RuntimeViewerCommunication

public final class RuntimeEngine: @unchecked Sendable {
    private enum DyldRegisterNotifications {
        static let addImage = Notification.Name("com.JH.RuntimeViewerCore.DyldRegisterObserver.addImageNotification")
        static let removeImage = Notification.Name("com.JH.RuntimeViewerCore.DyldRegisterObserver.removeImageNotification")
    }

    public static let shared = RuntimeEngine()

    private static let logger = Logger(subsystem: "com.JH.RuntimeViewerCore", category: "RuntimeEngine")

//    private let queue = AsyncQueue()

    @Published public private(set) var classList: [String] = []

    @Published public private(set) var protocolList: [String] = []

    @Published public private(set) var imageList: [String] = []

    @Published public private(set) var protocolToImage: [String: String] = [:]

    @Published public private(set) var imageToProtocols: [String: [String]] = [:]

    @Published public private(set) var imageNodes: [RuntimeNamedNode] = []

    @Published public private(set) var imageToSwiftSections: [String: RuntimeSwiftSections] = [:]

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

        var commandName: String { "com.JH.RuntimeViewerCore.RuntimeEngine.\(rawValue)" }
    }

    public let source: RuntimeSource

    private let shouldReload = PassthroughSubject<Void, Never>()

    private let communicator = RuntimeCommunicator()

    private var subscriptions: Set<AnyCancellable> = []

    /// The connection to the sender or receiver
    private var connection: RuntimeConnection?

    public init() {
        self.source = .local
        observeRuntime()
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

                observeRuntime()
            case .client:
                self.connection = try await communicator.connect(to: source) { connection in
                    self.connection = connection
                    self.setupMessageHandlerForClient()
                }
                print("Client connected")
            }
        } else {
            observeRuntime()
        }
    }

    private func setupMessageHandlerForServer() {
        setMessageHandlerBinding(forName: .isImageLoaded, of: self) { $0.isImageLoaded(path:) }
        setMessageHandlerBinding(forName: .loadImage, of: self) { $0.loadImage(at:) }
        setMessageHandlerBinding(forName: .classNamesInImage, of: self) { $0.classNamesIn(image:) }
        setMessageHandlerBinding(forName: .patchImagePathForDyld, of: self) { $0.patchImagePathForDyld(_:) }
        setMessageHandlerBinding(forName: .runtimeObjectHierarchy, of: self) { $0.runtimeObjectHierarchy(_:) }
        setMessageHandlerBinding(forName: .imageNameOfClassName, of: self) { $0.imageName(ofClass:) }
        connection?.setMessageHandler(name: CommandNames.semanticStringForRuntimeObjectWithOptions.commandName) { [unowned self] (request: SemanticStringRequest) -> Data? in
            try await semanticString(for: request.runtimeObject, options: request.options).map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        }
    }

    private func setupMessageHandlerForClient() {
        setMessageHandlerBinding(forName: .classList, to: \.classList)
        setMessageHandlerBinding(forName: .protocolList, to: \.protocolList)
        setMessageHandlerBinding(forName: .imageList, to: \.imageList)
        setMessageHandlerBinding(forName: .protocolToImage, to: \.protocolToImage)
        setMessageHandlerBinding(forName: .imageToProtocols, to: \.imageToProtocols)
        setMessageHandlerBinding(forName: .imageNodes, to: \.imageNodes)
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

    private func setMessageHandlerBinding<Response: Codable>(forName name: CommandNames, to keyPath: ReferenceWritableKeyPath<RuntimeEngine, Response>) {
        connection?.setMessageHandler(name: name.commandName) { [weak self] (response: Response) in
            guard let self else { return }
            self[keyPath: keyPath] = response
        }
    }

    public func reloadData() {
        Self.logger.debug("Start reload")
        classList = ObjCRuntime.classNames()
        protocolList = ObjCRuntime.protocolNames()
        imageList = DyldUtilities.imageNames()
        imageNodes = [DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode]
        Self.logger.debug("End reload")
        sendRemoteDataIfNeeded()
    }

    private func observeRuntime() {
        classList = ObjCRuntime.classNames()
        protocolList = ObjCRuntime.protocolNames()
        imageList = DyldUtilities.imageNames()
        let (protocolToImage, imageToProtocols) = ObjCRuntime.protocolImageTrackingFor(
            protocolList: protocolList, protocolToImage: [:], imageToProtocols: [:]
        ) ?? ([:], [:])
        self.protocolToImage = protocolToImage
        self.imageToProtocols = imageToProtocols
        imageNodes = [DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode]

        shouldReload
            .debounce(for: .milliseconds(15), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                reloadData()
            }
            .store(in: &subscriptions)

        $protocolList
            .combineLatest($protocolToImage, $imageToProtocols)
            .sink { [weak self] in
                guard let self else { return }
                guard let (protocolToImage, imageToProtocols) = ObjCRuntime.protocolImageTrackingFor(
                    protocolList: $0, protocolToImage: $1, imageToProtocols: $2
                ) else { return }
                self.protocolToImage = protocolToImage
                self.imageToProtocols = imageToProtocols
            }
            .store(in: &subscriptions)

//        observeDyldRegister()
        sendRemoteDataIfNeeded()
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
        _dyld_register_func_for_add_image { _, _ in
            NotificationCenter.default.post(name: DyldRegisterNotifications.addImage, object: nil)
        }

        _dyld_register_func_for_remove_image { _, _ in
            NotificationCenter.default.post(name: DyldRegisterNotifications.removeImage, object: nil)
        }

        NotificationCenter.default.publisher(for: DyldRegisterNotifications.addImage)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.shouldReload.send()
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: DyldRegisterNotifications.removeImage)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.shouldReload.send()
            }
            .store(in: &subscriptions)
    }

    private func startTimingReload() {
        Timer.publish(every: 15, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }

                let classList = ObjCRuntime.classNames()
                let protocolList = ObjCRuntime.protocolNames()

                let refClassList = self.classList
                let refProtocolList = self.protocolList

                if classList != refClassList {
                    Self.logger.error("Watchdog: classList is out-of-date")
                    self.classList = classList
                }
                if protocolList != refProtocolList {
                    Self.logger.error("Watchdog: protocolList is out-of-date")
                    self.protocolList = protocolList
                }
            }
            .store(in: &subscriptions)
    }

    private func _interface(for name: RuntimeObjectName, in image: String, options: RuntimeObjectInterface.GenerationOptions) -> RuntimeObjectInterface? {
        switch name.kind {
        case .swift:
            return try? imageToSwiftSections[image]?.interface(for: name, options: options.swiftDemangleOptions)
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
}

// MARK: - Requests

extension RuntimeEngine {
    enum RequestError: Error {
        case senderConnectionIsLose
    }

    private func request<T>(local: () throws -> T, remote: (_ senderConnection: RuntimeConnection) async throws -> T) async throws -> T {
        if let remoteRole = source.remoteRole, remoteRole.isClient {
            guard let connection else { throw RequestError.senderConnectionIsLose }
            return try await remote(connection)
        } else {
            return try local()
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
            reloadData()
        } remote: {
            try await $0.sendMessage(name: .loadImage, request: path)
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
        let image: String
        let options: RuntimeObjectInterface.GenerationOptions
    }

    public func interface(for name: RuntimeObjectName, in image: String, options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface? {
        try await request {
            _interface(for: name, in: image, options: options)
        } remote: { senderConnection in
            return try await senderConnection.sendMessage(name: .interfaceForRuntimeObjectInImageWithOptions, request: InterfaceRequest(name: name, image: image, options: options))
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
