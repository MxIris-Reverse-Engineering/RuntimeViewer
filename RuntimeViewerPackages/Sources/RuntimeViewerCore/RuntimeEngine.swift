import OSLog
import Combine
import Foundation
import MachO.dyld
import ClassDumpRuntime
import FoundationToolbox
#if os(macOS)
import SwiftyXPC
import RuntimeViewerCommunication
#endif

public final class RuntimeEngine {
    private enum DyldRegisterNotifications {
        static let addImage = Notification.Name("com.JH.RuntimeViewerCore.DyldRegisterObserver.addImageNotification")
        static let removeImage = Notification.Name("com.JH.RuntimeViewerCore.DyldRegisterObserver.removeImageNotification")
    }

    public static let shared = RuntimeEngine()

    private static let logger = Logger(subsystem: "com.JH.RuntimeViewerCore", category: "RuntimeListings")

    @Published public private(set) var classList: [String] = [] {
        didSet {
            #if os(macOS)
            if case let .remote(_, _, role) = source, role.isServer, let connection {
                Task {
                    do {
                        try await connection.sendMessage(name: CommandIdentifiers.classList, request: classList)
                    } catch {
                        Self.logger.error("\(error)")
                    }
                }
            }
            #endif
        }
    }

    @Published public private(set) var protocolList: [String] = [] {
        didSet {
            #if os(macOS)
            if case let .remote(_, _, role) = source, role.isServer, let connection {
                Task {
                    do {
                        try await connection.sendMessage(name: CommandIdentifiers.protocolList, request: protocolList)
                    } catch {
                        Self.logger.error("\(error)")
                    }
                }
            }
            #endif
        }
    }

    @Published public private(set) var imageList: [String] = [] {
        didSet {
            #if os(macOS)
            if case let .remote(_, _, role) = source, role.isServer, let connection {
                Task {
                    do {
                        try await connection.sendMessage(name: CommandIdentifiers.imageList, request: imageList)
                    } catch {
                        Self.logger.error("\(error)")
                    }
                }
            }
            #endif
        }
    }

    @Published public private(set) var protocolToImage: [String: String] = [:] {
        didSet {
            #if os(macOS)
            if case let .remote(_, _, role) = source, role.isServer, let connection {
                Task {
                    do {
                        try await connection.sendMessage(name: CommandIdentifiers.protocolToImage, request: protocolToImage)
                    } catch {
                        Self.logger.error("\(error)")
                    }
                }
            }
            #endif
        }
    }

    @Published public private(set) var imageToProtocols: [String: [String]] = [:] {
        didSet {
            #if os(macOS)
            if case let .remote(_, _, role) = source, role.isServer, let connection {
                Task {
                    do {
                        try await connection.sendMessage(name: CommandIdentifiers.imageToProtocols, request: imageToProtocols)
                    } catch {
                        Self.logger.error("\(error)")
                    }
                }
            }
            #endif
        }
    }

    @Published public private(set) var imageNodes: [RuntimeNamedNode] = [] {
        didSet {
            #if os(macOS)
            if case let .remote(_, _, role) = source, role.isServer, let connection {
                Task {
                    do {
                        try await connection.sendMessage(name: CommandIdentifiers.imageNodes, request: imageNodes)
                    } catch {
                        Self.logger.error("\(error)")
                    }
                }
            }
            #endif
        }
    }

    private enum CommandIdentifiers {
        static let classList = command("classList")
        static let protocolList = command("protocolList")
        static let imageList = command("imageList")
        static let protocolToImage = command("protocolToImage")
        static let imageToProtocols = command("imageToProtocols")
        static let loadImage = command("loadImage")
        static let senderLaunched = command("senderLaunched")
        static let isImageLoaded = command("isImageLoaded")
        static let classNamesInImage = command("classNamesInImage")
        static let patchImagePathForDyld = command("patchImagePathForDyld")
        static let semanticStringForRuntimeObjectWithOptions = command("semanticStringForRuntimeObjectWithOptions")
        static let imageNodes = command("imageNodes")
        static let runtimeObjectHierarchy = command("runtimeObjectHierarchy")
        static let runtimeObjectInfo = command("runtimeObjectInfo")
        static let imageNameOfClassName = command("imageNameOfClassName")
        static func command(_ command: String) -> String { "com.JH.RuntimeViewer.RuntimeListings.\(command)" }
    }

    public let source: RuntimeSource

    private let shouldReload = PassthroughSubject<Void, Never>()

    private var subscriptions: Set<AnyCancellable> = []

    #if os(macOS)
    /// The connection to communicate with the mach service
    private var serviceConnection: SwiftyXPC.XPCConnection?
    /// The listener for the sender or receiver
    private var listener: SwiftyXPC.XPCListener?
    /// The connection to the sender or receiver
    private var connection: SwiftyXPC.XPCConnection?
    #endif

    public init(source: RuntimeSource = .local) {
        self.source = source
        switch source {
        case .local:
            observeRuntime()
        #if os(macOS)
        case let .remote(_, identifier, role):
            Task {
                do {
                    let serviceConnection = try await connectToMachService()
                    switch role {
                    case .server:
                        try await setupMessageHandlerForServer(with: serviceConnection, identifier: identifier)
                    case .client:
                        try await setupMessageHandlerForClient(with: serviceConnection, identifier: identifier)
                    }
                } catch {
                    Self.logger.error("\(error)")
                }
            }
        #endif
        }
    }

    #if os(macOS)
    private func connectToMachService() async throws -> SwiftyXPC.XPCConnection {
        let serviceConnection = try XPCConnection(type: .remoteMachService(serviceName: RuntimeViewerMachServiceName, isPrivilegedHelperTool: true))
        serviceConnection.activate()
        self.serviceConnection = serviceConnection
        try await serviceConnection.sendMessage(request: PingRequest())
        Self.logger.info("Ping successfully")
        return serviceConnection
    }

    private func setupMessageHandlerForServer(with serviceConnection: XPCConnection, identifier: RuntimeSource.Identifier) async throws {
        let listener = try XPCListener(type: .anonymous, codeSigningRequirement: nil)
        self.listener = listener
        let response = try await serviceConnection.sendMessage(request: FetchEndpointRequest(identifier: identifier.rawValue))
        let clientConnection = try XPCConnection(type: .remoteServiceFromEndpoint(response.endpoint))
        clientConnection.activate()
        connection = clientConnection
        try await clientConnection.sendMessage(request: PingRequest())
        Self.logger.info("Ping client successfully")
        observeRuntime()
        listener.setMessageHandler(name: PingRequest.identifier) { (_: XPCConnection, _: PingRequest) -> PingRequest.Response in
            return .empty
        }
        setMessageHandlerBinding(forName: CommandIdentifiers.isImageLoaded, of: self) { $0.isImageLoaded(path:) }
        setMessageHandlerBinding(forName: CommandIdentifiers.loadImage, of: self) { $0.loadImage(at:) }
        setMessageHandlerBinding(forName: CommandIdentifiers.classNamesInImage, of: self) { $0.classNamesIn(image:) }
        setMessageHandlerBinding(forName: CommandIdentifiers.patchImagePathForDyld, of: self) { $0.patchImagePathForDyld(_:) }
        setMessageHandlerBinding(forName: CommandIdentifiers.runtimeObjectHierarchy, of: self) { $0.runtimeObjectHierarchy(_:) }
        setMessageHandlerBinding(forName: CommandIdentifiers.imageNameOfClassName, of: self) { $0.imageName(ofClass:) }

        listener.setMessageHandler(name: CommandIdentifiers.semanticStringForRuntimeObjectWithOptions) { [unowned self] (_: XPCConnection, request: SemanticStringRequest) -> Data? in
            try await semanticString(for: request.runtimeObject, options: request.options).map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        }

        listener.activate()

        try await clientConnection.sendMessage(name: CommandIdentifiers.senderLaunched, request: listener.endpoint)
    }

    private func setupMessageHandlerForClient(with serviceConnection: XPCConnection, identifier: RuntimeSource.Identifier) async throws {
        let listener = try XPCListener(type: .anonymous, codeSigningRequirement: nil)
        self.listener = listener
        setMessageHandlerBinding(forName: CommandIdentifiers.classList, to: \.classList)
        setMessageHandlerBinding(forName: CommandIdentifiers.protocolList, to: \.protocolList)
        setMessageHandlerBinding(forName: CommandIdentifiers.imageList, to: \.imageList)
        setMessageHandlerBinding(forName: CommandIdentifiers.protocolToImage, to: \.protocolToImage)
        setMessageHandlerBinding(forName: CommandIdentifiers.imageToProtocols, to: \.imageToProtocols)
        setMessageHandlerBinding(forName: CommandIdentifiers.imageNodes, to: \.imageNodes)

        listener.setMessageHandler(name: CommandIdentifiers.senderLaunched) { [weak self] (_: XPCConnection, endpoint: XPCEndpoint) in
            guard let self else { return }
            let serverConnection = try XPCConnection(type: .remoteServiceFromEndpoint(endpoint))
            serverConnection.activate()
            self.connection = serverConnection
            _ = try await serverConnection.sendMessage(request: PingRequest())
            Self.logger.info("Ping server successfully")
        }

        listener.setMessageHandler(name: PingRequest.identifier) { (_: XPCConnection, _: PingRequest) -> PingRequest.Response in
            return .empty
        }

        listener.activate()
        try await serviceConnection.sendMessage(request: RegisterEndpointRequest(identifier: identifier.rawValue, endpoint: listener.endpoint))
        if identifier == .macCatalyst {
            try await serviceConnection.sendMessage(request: LaunchCatalystHelperRequest(helperURL: RuntimeViewerCatalystHelperLauncher.helperURL))
        }
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable>(forName name: String, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Void)) {
        listener?.setMessageHandler(name: name) { [unowned object] (_: XPCConnection, request: Request) in
            try await function(object)(request)
        }
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable, Response: Codable>(forName name: String, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Response)) {
        listener?.setMessageHandler(name: name) { [unowned object] (_: XPCConnection, request: Request) -> Response in
            let result = try await function(object)(request)
            return result
        }
    }

    private func setMessageHandlerBinding<Response: Codable>(forName name: String, to keyPath: ReferenceWritableKeyPath<RuntimeEngine, Response>) {
        listener?.setMessageHandler(name: name) { [weak self] (_: XPCConnection, value: Response) in
            guard let self else { return }
            self[keyPath: keyPath] = value
        }
    }

    #endif

    private func reloadData() {
        Self.logger.debug("Start reload")
        classList = Self.classNames()
        protocolList = Self.protocolNames()
        imageList = Self.imageNames()
        imageNodes = [Self.dyldSharedCacheImageRootNode, Self.otherImageRootNode]
        Self.logger.debug("End reload")
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

#if !os(macOS)
typealias XPCConnection = Void
#endif

// MARK: - Requests

extension RuntimeEngine {
    enum RequestError: Error {
        case senderConnectionIsLose
    }

    private func request<T>(local: () throws -> T, remote: (_ senderConnection: XPCConnection) async throws -> T) async throws -> T {
        switch source {
        case .local:
            return try local()
        #if os(macOS)
        case let .remote(_, _, role):
            if role.isServer {
                return try local()
            } else {
                guard let connection else { throw RequestError.senderConnectionIsLose }
                return try await remote(connection)
            }
        #endif
        }
    }

    public func isImageLoaded(path: String) async throws -> Bool {
        try await request {
            imageList.contains(Self.patchImagePathForDyld(path))
        } remote: {
            #if os(macOS)
            return try await $0.sendMessage(name: CommandIdentifiers.isImageLoaded, request: path)
            #else
            fatalError()
            #endif
        }
    }

    public func loadImage(at path: String) async throws {
        try await request {
            try Self.loadImage(at: path)
        } remote: {
            #if os(macOS)
            try await $0.sendMessage(name: CommandIdentifiers.isImageLoaded, request: path)
            #endif
        }
    }

    public func classNamesIn(image: String) async throws -> [String] {
        try await request {
            Self.classNamesIn(image: image)
        } remote: {
            #if os(macOS)
            return try await $0.sendMessage(name: CommandIdentifiers.classNamesInImage, request: image)
            #else
            fatalError()
            #endif
        }
    }

    public func patchImagePathForDyld(_ imagePath: String) async throws -> String {
        try await request {
            Self.patchImagePathForDyld(imagePath)
        } remote: {
            #if os(macOS)
            return try await $0.sendMessage(name: CommandIdentifiers.patchImagePathForDyld, request: imagePath)
            #else
            fatalError()
            #endif
        }
    }

    public func imageName(ofClass className: String) async throws -> String? {
        try await request {
            Self.imageName(ofClass: className)
        } remote: {
            #if os(macOS)
            return try await $0.sendMessage(name: CommandIdentifiers.imageNameOfClassName, request: className)
            #else
            fatalError()
            #endif
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
            #if os(macOS)
            let semanticStringData: Data? = try await $0.sendMessage(name: CommandIdentifiers.semanticStringForRuntimeObjectWithOptions, request: SemanticStringRequest(runtimeObject: runtimeObject, options: options))
            return try semanticStringData.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: CDSemanticString.self, from: $0) }
            #else
            fatalError()
            #endif
        }
    }

    public func runtimeObjectHierarchy(_ runtimeObject: RuntimeObjectType) async throws -> [String] {
        try await request {
            runtimeObject.hierarchy()
        } remote: {
            #if os(macOS)
            return try await $0.sendMessage(name: CommandIdentifiers.runtimeObjectHierarchy, request: runtimeObject)
            #else
            fatalError()
            #endif
        }
    }

    public func runtimeObjectInfo(_ runtimeObject: RuntimeObjectType) async throws -> RuntimeObjectInfo {
        try await request {
            try runtimeObject.info()
        } remote: {
            #if os(macOS)
            return try await $0.sendMessage(name: CommandIdentifiers.runtimeObjectInfo, request: runtimeObject)
            #else
            fatalError()
            #endif
        }
    }

    public func injectApplication(pid: pid_t, dylibURL: URL) async throws {
        enum Error: Swift.Error {
            case noMachServiceConnection
        }

        guard let serviceConnection else { throw Error.noMachServiceConnection }
        try await serviceConnection.sendMessage(request: InjectApplicationRequest(pid: pid, dylibURL: dylibURL))
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
                logger.error("Failed to find protocol named '\(protocolName, privacy: .public)'")
                continue
            }

            guard dladdr(protocol_getName(prtcl), &dlInfo) != 0 else {
                logger.warning("Failed to get dl_info for protocol named '\(protocolName, privacy: .public)'")
                continue
            }

            guard let abc = dlInfo.dli_fname else {
                logger.error("Failed to get dli_fname for protocol named '\(protocolName, privacy: .public)'")
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
