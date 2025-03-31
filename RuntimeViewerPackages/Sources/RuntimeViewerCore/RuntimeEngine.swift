import OSLog
import Combine
import Foundation
import MachO.dyld
import ClassDumpRuntime
import FoundationToolbox
import RuntimeViewerCommunication
import Queue

public final class RuntimeEngine {
    private enum DyldRegisterNotifications {
        static let addImage = Notification.Name("com.JH.RuntimeViewerCore.DyldRegisterObserver.addImageNotification")
        static let removeImage = Notification.Name("com.JH.RuntimeViewerCore.DyldRegisterObserver.removeImageNotification")
    }

    public static let shared = RuntimeEngine()

    private static let logger = Logger(subsystem: "com.JH.RuntimeViewerCore", category: "RuntimeEngine")

    private let queue = AsyncQueue()

    @Published public private(set) var classList: [String] = [] {
        didSet {
//            if let role = source.remoteRole, role.isServer, let connection {
//                queue.addOperation {
//                    try await connection.sendMessage(name: CommandIdentifiers.classList, request: self.classList)
//                }
//            }
        }
    }

    @Published public private(set) var protocolList: [String] = [] {
        didSet {
//            if let role = source.remoteRole, role.isServer, let connection {
//                queue.addOperation {
//                    try await connection.sendMessage(name: CommandIdentifiers.protocolList, request: self.protocolList)
//                }
//            }
        }
    }

    @Published public private(set) var imageList: [String] = [] {
        didSet {
//            if let role = source.remoteRole, role.isServer, let connection {
//                queue.addOperation {
//                    try await connection.sendMessage(name: CommandIdentifiers.imageList, request: self.imageList)
//                }
//            }
        }
    }

    @Published public private(set) var protocolToImage: [String: String] = [:] {
        didSet {
//            if let role = source.remoteRole, role.isServer, let connection {
//                queue.addOperation {
//                    try await connection.sendMessage(name: CommandIdentifiers.protocolToImage, request: self.protocolToImage)
//                }
//            }
        }
    }

    @Published public private(set) var imageToProtocols: [String: [String]] = [:] {
        didSet {
//            if let role = source.remoteRole, role.isServer, let connection {
//                queue.addOperation {
//                    try await connection.sendMessage(name: CommandIdentifiers.imageToProtocols, request: self.imageToProtocols)
//                }
//            }
        }
    }

    @Published public private(set) var imageNodes: [RuntimeNamedNode] = [] {
        didSet {
//            if let role = source.remoteRole, role.isServer, let connection {
//                queue.addOperation {
//                    try await connection.sendMessage(name: CommandIdentifiers.imageNodes, request: self.imageNodes)
//                }
//            }
        }
    }

    private enum CommandIdentifiers {
        static let classList = command("classList")
        static let protocolList = command("protocolList")
        static let imageList = command("imageList")
        static let protocolToImage = command("protocolToImage")
        static let imageToProtocols = command("imageToProtocols")
        static let loadImage = command("loadImage")
        static let serverLaunched = command("serverLaunched")
        static let isImageLoaded = command("isImageLoaded")
        static let classNamesInImage = command("classNamesInImage")
        static let patchImagePathForDyld = command("patchImagePathForDyld")
        static let semanticStringForRuntimeObjectWithOptions = command("semanticStringForRuntimeObjectWithOptions")
        static let imageNodes = command("imageNodes")
        static let runtimeObjectHierarchy = command("runtimeObjectHierarchy")
        static let runtimeObjectInfo = command("runtimeObjectInfo")
        static let imageNameOfClassName = command("imageNameOfClassName")
        static let observeRuntime = command("observeRuntime")
        static func command(_ command: String) -> String { "com.JH.RuntimeViewer.RuntimeListings.\(command)" }
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
            }
        } else {
            observeRuntime()
        }
    }

    private func setupMessageHandlerForServer() {
        setMessageHandlerBinding(forName: CommandIdentifiers.isImageLoaded, of: self) { $0.isImageLoaded(path:) }
        setMessageHandlerBinding(forName: CommandIdentifiers.loadImage, of: self) { $0.loadImage(at:) }
        setMessageHandlerBinding(forName: CommandIdentifiers.classNamesInImage, of: self) { $0.classNamesIn(image:) }
        setMessageHandlerBinding(forName: CommandIdentifiers.patchImagePathForDyld, of: self) { $0.patchImagePathForDyld(_:) }
        setMessageHandlerBinding(forName: CommandIdentifiers.runtimeObjectHierarchy, of: self) { $0.runtimeObjectHierarchy(_:) }
        setMessageHandlerBinding(forName: CommandIdentifiers.imageNameOfClassName, of: self) { $0.imageName(ofClass:) }
        connection?.setMessageHandler(name: CommandIdentifiers.semanticStringForRuntimeObjectWithOptions) { [unowned self] (request: SemanticStringRequest) -> Data? in
            try await semanticString(for: request.runtimeObject, options: request.options).map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        }
    }

    private func setupMessageHandlerForClient() {
        setMessageHandlerBinding(forName: CommandIdentifiers.classList, to: \.classList)
        setMessageHandlerBinding(forName: CommandIdentifiers.protocolList, to: \.protocolList)
        setMessageHandlerBinding(forName: CommandIdentifiers.imageList, to: \.imageList)
        setMessageHandlerBinding(forName: CommandIdentifiers.protocolToImage, to: \.protocolToImage)
        setMessageHandlerBinding(forName: CommandIdentifiers.imageToProtocols, to: \.imageToProtocols)
        setMessageHandlerBinding(forName: CommandIdentifiers.imageNodes, to: \.imageNodes)
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable>(forName name: String, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Void)) {
        connection?.setMessageHandler(name: name) { [unowned object] (request: Request) in
            try await function(object)(request)
        }
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable, Response: Codable>(forName name: String, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Response)) {
        connection?.setMessageHandler(name: name) { [unowned object] (request: Request) -> Response in
            let result = try await function(object)(request)
            return result
        }
    }

    private func setMessageHandlerBinding<Response: Codable>(forName name: String, to keyPath: ReferenceWritableKeyPath<RuntimeEngine, Response>) {
        connection?.setMessageHandler(name: name) { [weak self] (response: Response) in
            guard let self else { return }
            self[keyPath: keyPath] = response
        }
    }

    public func reloadData() {
        Self.logger.debug("Start reload")
        classList = Self.classNames()
        protocolList = Self.protocolNames()
        imageList = Self.imageNames()
        imageNodes = [Self.dyldSharedCacheImageRootNode, Self.otherImageRootNode]
        Self.logger.debug("End reload")
        sendRemoteDataIfNeeded()
    }

    private func observeRuntime() {
        classList = Self.classNames()
        protocolList = Self.protocolNames()
        imageList = Self.imageNames()
        let (protocolToImage, imageToProtocols) = Self.protocolImageTrackingFor(
            protocolList: protocolList, protocolToImage: [:], imageToProtocols: [:]
        ) ?? ([:], [:])
        self.protocolToImage = protocolToImage
        self.imageToProtocols = imageToProtocols
        imageNodes = [Self.dyldSharedCacheImageRootNode, Self.otherImageRootNode]

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
                guard let (protocolToImage, imageToProtocols) = Self.protocolImageTrackingFor(
                    protocolList: $0, protocolToImage: $1, imageToProtocols: $2
                ) else { return }
                self.protocolToImage = protocolToImage
                self.imageToProtocols = imageToProtocols
            }
            .store(in: &subscriptions)

        sendRemoteDataIfNeeded()
    }

    private func sendRemoteDataIfNeeded() {
        guard let role = source.remoteRole, role.isServer, let connection else { return }
        Task {
            try await connection.sendMessage(name: CommandIdentifiers.classList, request: self.classList)
            try await connection.sendMessage(name: CommandIdentifiers.protocolList, request: self.protocolList)
            try await connection.sendMessage(name: CommandIdentifiers.imageList, request: self.imageList)
            try await connection.sendMessage(name: CommandIdentifiers.imageNodes, request: self.imageNodes)
            try await connection.sendMessage(name: CommandIdentifiers.protocolToImage, request: self.protocolToImage)
            try await connection.sendMessage(name: CommandIdentifiers.imageToProtocols, request: self.imageToProtocols)
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

                let classList = Self.classNames()
                let protocolList = Self.protocolNames()

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
            imageList.contains(Self.patchImagePathForDyld(path))
        } remote: {
            return try await $0.sendMessage(name: CommandIdentifiers.isImageLoaded, request: path)
        }
    }

    public func loadImage(at path: String) async throws {
        try await request {
            try Self.loadImage(at: path)
        } remote: {
            try await $0.sendMessage(name: CommandIdentifiers.loadImage, request: path)
        }
    }

    public func classNamesIn(image: String) async throws -> [String] {
        try await request {
            Self.classNamesIn(image: image)
        } remote: {
            return try await $0.sendMessage(name: CommandIdentifiers.classNamesInImage, request: image)
        }
    }

    public func patchImagePathForDyld(_ imagePath: String) async throws -> String {
        try await request {
            Self.patchImagePathForDyld(imagePath)
        } remote: {
            return try await $0.sendMessage(name: CommandIdentifiers.patchImagePathForDyld, request: imagePath)
        }
    }

    public func imageName(ofClass className: String) async throws -> String? {
        try await request {
            Self.imageName(ofClass: className)
        } remote: {
            return try await $0.sendMessage(name: CommandIdentifiers.imageNameOfClassName, request: className)
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
            let semanticStringData: Data? = try await $0.sendMessage(name: CommandIdentifiers.semanticStringForRuntimeObjectWithOptions, request: SemanticStringRequest(runtimeObject: runtimeObject, options: options))
            return try semanticStringData.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: CDSemanticString.self, from: $0) }
        }
    }

    public func runtimeObjectHierarchy(_ runtimeObject: RuntimeObjectType) async throws -> [String] {
        try await request {
            runtimeObject.hierarchy()
        } remote: {
            return try await $0.sendMessage(name: CommandIdentifiers.runtimeObjectHierarchy, request: runtimeObject)
        }
    }

    public func runtimeObjectInfo(_ runtimeObject: RuntimeObjectType) async throws -> RuntimeObjectInfo {
        try await request {
            try runtimeObject.info()
        } remote: {
            return try await $0.sendMessage(name: CommandIdentifiers.runtimeObjectInfo, request: runtimeObject)
        }
    }
}

extension RuntimeEngine {
    private static func protocolImageTrackingFor(
        protocolList: [String], protocolToImage: [String: String], imageToProtocols: [String: [String]]
    ) -> ([String: String], [String: [String]])? {
        var protocolToImageCopy = protocolToImage
        var imageToProtocolsCopy = imageToProtocols

        var dlInfo = dl_info()
        var didChange = false

        for protocolName in protocolList {
            guard protocolToImageCopy[protocolName] == nil else { continue } // happy path

            guard let prtcl = NSProtocolFromString(protocolName) else {
//                logger.error("Failed to find protocol named '\(protocolName, privacy: .public)'")
                continue
            }

            guard dladdr(protocol_getName(prtcl), &dlInfo) != 0 else {
//                logger.warning("Failed to get dl_info for protocol named '\(protocolName, privacy: .public)'")
                continue
            }

            guard let abc = dlInfo.dli_fname else {
//                logger.error("Failed to get dli_fname for protocol named '\(protocolName, privacy: .public)'")
                continue
            }

            let imageName = String(cString: abc)
            protocolToImageCopy[protocolName] = imageName
            imageToProtocolsCopy[imageName, default: []].append(protocolName)

            didChange = true
        }
        guard didChange else { return nil }
        return (protocolToImageCopy, imageToProtocolsCopy)
    }
}

extension RuntimeEngine {
    private class func classNames() -> [String] {
        CDUtilities.classNames()
    }

    private class func imageNames() -> [String] {
        (0...)
            .lazy
            .map(_dyld_get_image_name)
            .prefix { $0 != nil }
            .compactMap { $0 }
            .map { String(cString: $0) }
    }

    private class func protocolNames() -> [String] {
        var protocolCount: UInt32 = 0
        guard let protocolList = objc_copyProtocolList(&protocolCount) else { return [] }

        let names = sequence(first: protocolList) { $0.successor() }
            .prefix(Int(protocolCount))
            .map { NSStringFromProtocol($0.pointee) }

        return names
    }

    private class func imageName(ofClass className: String) -> String? {
        class_getImageName(NSClassFromString(className)).map { String(cString: $0) }
    }

    private class func classNamesIn(image: String) -> [String] {
        patchImagePathForDyld(image).withCString { cString in
            var classCount: UInt32 = 0
            guard let classNames = objc_copyClassNamesForImage(cString, &classCount) else { return [] }

            let names = sequence(first: classNames) { $0.successor() }
                .prefix(Int(classCount))
                .map { String(cString: $0.pointee) }

            classNames.deallocate()

            return names
        }
    }

    private class func patchImagePathForDyld(_ imagePath: String) -> String {
        guard imagePath.starts(with: "/") else { return imagePath }
        let rootPath = ProcessInfo.processInfo.environment["DYLD_ROOT_PATH"]
        guard let rootPath else { return imagePath }
        return rootPath.appending(imagePath)
    }

    private class func loadImage(at path: String) throws {
        try path.withCString { cString in
            let handle = dlopen(cString, RTLD_LAZY)
            // get the error and copy it into an object we control since the error is shared
            let errPtr = dlerror()
            let errStr = errPtr.map { String(cString: $0) }
            guard handle != nil else {
                throw DlOpenError(message: errStr)
            }
        }
    }

    private class var dyldSharedCacheImageRootNode: RuntimeNamedNode {
        return .rootNode(for: CDUtilities.dyldSharedCacheImagePaths(), name: "Dyld Shared Cache")
    }

    private class var otherImageRootNode: RuntimeNamedNode {
        let dyldSharedCacheImagePaths = CDUtilities.dyldSharedCacheImagePaths()
        let allImagePaths = imageNames()
        let otherImagePaths = allImagePaths.filter { !dyldSharedCacheImagePaths.contains($0) }
        return .rootNode(for: otherImagePaths, name: "Others")
    }
}

public struct DlOpenError: Error {
    public let message: String?
}
