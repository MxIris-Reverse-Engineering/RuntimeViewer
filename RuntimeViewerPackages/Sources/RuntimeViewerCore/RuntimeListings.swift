import Foundation
import Combine
import ClassDumpRuntime
import MachO.dyld
import OSLog
#if os(macOS)
import RuntimeViewerService
import SwiftyXPC
#endif
import FoundationToolbox

enum DyldRegisterNotifications {
    static let addImage = Notification.Name("com.JH.RuntimeViewerCore.DyldRegisterObserver.addImageNotification")
    static let removeImage = Notification.Name("com.JH.RuntimeViewerCore.DyldRegisterObserver.removeImageNotification")
}

public enum RuntimeSource: CustomStringConvertible {
    case native
    @available(iOS, unavailable)
    @available(tvOS, unavailable)
    @available(watchOS, unavailable)
    @available(visionOS, unavailable)
    case macCatalyst(isSender: Bool)

    public var description: String {
        switch self {
        case .native: return "Native"
        case .macCatalyst: return "MacCatalyst"
        }
    }
}

public final class RuntimeListings {
    public static let shared = RuntimeListings()

    private static let logger = Logger(subsystem: "com.JH.RuntimeViewerCore", category: "RuntimeListings")

    @Published public private(set) var classList: [String] = [] {
        didSet {
            #if os(macOS)
            if case let .macCatalyst(isSender) = source, isSender, let connection {
                Task {
                    do {
                        try await connection.sendMessage(name: ListingsCommandSet.classList, request: classList)
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
            if case let .macCatalyst(isSender) = source, isSender, let connection {
                Task {
                    do {
                        try await connection.sendMessage(name: ListingsCommandSet.protocolList, request: protocolList)
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
            if case let .macCatalyst(isSender) = source, isSender, let connection {
                Task {
                    do {
                        try await connection.sendMessage(name: ListingsCommandSet.imageList, request: imageList)
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
            if case let .macCatalyst(isSender) = source, isSender, let connection {
                Task {
                    do {
                        try await connection.sendMessage(name: ListingsCommandSet.protocolToImage, request: protocolToImage)
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
            if case let .macCatalyst(isSender) = source, isSender, let connection {
                Task {
                    do {
                        try await connection.sendMessage(name: ListingsCommandSet.imageToProtocols, request: imageToProtocols)
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
            if case let .macCatalyst(isSender) = source, isSender, let connection {
                Task {
                    do {
                        try await connection.sendMessage(name: ListingsCommandSet.imageNodes, request: imageNodes)
                    } catch {
                        Self.logger.error("\(error)")
                    }
                }
            }
            #endif
        }
    }

    private enum ListingsCommandSet {
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

    public init(source: RuntimeSource = .native) {
        self.source = source
        switch source {
        case .native:
            observeRuntime()
        #if os(macOS)
        case let .macCatalyst(isSender):
            Task {
                do {
                    let serviceConnection = try await connectToMachService()
                    if isSender {
                        try await setupMessageHandlerForSender(with: serviceConnection)
                    } else {
                        try await setupMessageHandlerForReceiver(with: serviceConnection)
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
        let serviceConnection = try XPCConnection(type: .remoteMachService(serviceName: RuntimeViewerService.serviceName, isPrivilegedHelperTool: true))
        serviceConnection.activate()
        self.serviceConnection = serviceConnection
        let ping: String = try await serviceConnection.sendMessage(name: CommandSet.ping)
        Self.logger.info("\(ping)")
        return serviceConnection
    }

    private func setupMessageHandlerForSender(with serviceConnection: XPCConnection) async throws {
        let listener = try XPCListener(type: .anonymous, codeSigningRequirement: nil)
        self.listener = listener
        let endpoint: XPCEndpoint = try await serviceConnection.sendMessage(name: CommandSet.fetchEndpoint)
        let receiverConnection = try XPCConnection(type: .remoteServiceFromEndpoint(endpoint))
        receiverConnection.activate()
        connection = receiverConnection
        let ping: String = try await receiverConnection.sendMessage(name: CommandSet.ping)
        Self.logger.info("\(ping)")
        observeRuntime()
        listener.setMessageHandler(name: CommandSet.ping) { connection in
            return "Ping sender successfully."
        }
        setMessageHandlerBinding(forName: ListingsCommandSet.isImageLoaded, of: self) { $0.isImageLoaded(path:) }
        setMessageHandlerBinding(forName: ListingsCommandSet.loadImage, of: self) { $0.loadImage(at:) }
        setMessageHandlerBinding(forName: ListingsCommandSet.classNamesInImage, of: self) { $0.classNamesIn(image:) }
        setMessageHandlerBinding(forName: ListingsCommandSet.patchImagePathForDyld, of: self) { $0.patchImagePathForDyld(_:) }
        setMessageHandlerBinding(forName: ListingsCommandSet.runtimeObjectHierarchy, of: self) { $0.runtimeObjectHierarchy(_:) }
        setMessageHandlerBinding(forName: ListingsCommandSet.imageNameOfClassName, of: self) { $0.imageName(ofClass:) }
        
        listener.setMessageHandler(name: ListingsCommandSet.semanticStringForRuntimeObjectWithOptions) { [unowned self] (connection: XPCConnection, request: SemanticStringRequest) -> Data? in
            try await semanticString(for: request.runtimeObject, options: request.options).map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        }

        listener.activate()

        try await receiverConnection.sendMessage(name: ListingsCommandSet.senderLaunched, request: listener.endpoint)
    }

    private func setupMessageHandlerForReceiver(with serviceConnection: XPCConnection) async throws {
        let listener = try XPCListener(type: .anonymous, codeSigningRequirement: nil)
        self.listener = listener
        setMessageHandlerBinding(forName: ListingsCommandSet.classList, to: \.classList)
        setMessageHandlerBinding(forName: ListingsCommandSet.protocolList, to: \.protocolList)
        setMessageHandlerBinding(forName: ListingsCommandSet.imageList, to: \.imageList)
        setMessageHandlerBinding(forName: ListingsCommandSet.protocolToImage, to: \.protocolToImage)
        setMessageHandlerBinding(forName: ListingsCommandSet.imageToProtocols, to: \.imageToProtocols)
        setMessageHandlerBinding(forName: ListingsCommandSet.imageNodes, to: \.imageNodes)

        listener.setMessageHandler(name: ListingsCommandSet.senderLaunched) { [weak self] (connection: XPCConnection, endpoint: XPCEndpoint) in
            guard let self else { return }
            let senderConnection = try XPCConnection(type: .remoteServiceFromEndpoint(endpoint))
            senderConnection.activate()
            self.connection = senderConnection
            let ping: String = try await senderConnection.sendMessage(name: CommandSet.ping)
            Self.logger.info("\(ping)")
        }

        listener.setMessageHandler(name: CommandSet.ping) { connection in
            return "Ping receiver successfully."
        }

        listener.activate()
        try await serviceConnection.sendMessage(name: CommandSet.updateEndpoint, request: listener.endpoint)
        try await serviceConnection.sendMessage(name: CommandSet.launchCatalystHelper, request: RuntimeViewerCatalystHelperLauncher.helperURL)
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable>(forName name: String, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Void)) {
        listener?.setMessageHandler(name: name) { [unowned object] (connection: XPCConnection, request: Request) in
            try await function(object)(request)
        }
    }

    private func setMessageHandlerBinding<Object: AnyObject, Request: Codable, Response: Codable>(forName name: String, of object: Object, to function: @escaping (Object) -> ((Request) async throws -> Response)) {
        listener?.setMessageHandler(name: name) { [unowned object] (connection: XPCConnection, request: Request) -> Response in
            let result = try await function(object)(request)
            return result
        }
    }

    private func setMessageHandlerBinding<Response: Codable>(forName name: String, to keyPath: ReferenceWritableKeyPath<RuntimeListings, Response>) {
        listener?.setMessageHandler(name: name) { [weak self] (connection: XPCConnection, value: Response) in
            guard let self else { return }
            self[keyPath: keyPath] = value
        }
    }

    #endif

    private func reloadData() {
        Self.logger.debug("Start reload")
        classList = CDUtilities.classNames()
        protocolList = CDUtilities.protocolNames()
        imageList = CDUtilities.imageNames()
        imageNodes = [CDUtilities.dyldSharedCacheImageRootNode, CDUtilities.otherImageRootNode]
        Self.logger.debug("End reload")
    }

    private func observeRuntime() {
        classList = CDUtilities.classNames()
        protocolList = CDUtilities.protocolNames()
        imageList = CDUtilities.imageNames()
        let (protocolToImage, imageToProtocols) = Self.protocolImageTrackingFor(
            protocolList: protocolList, protocolToImage: [:], imageToProtocols: [:]
        ) ?? ([:], [:])
        self.protocolToImage = protocolToImage
        self.imageToProtocols = imageToProtocols
        imageNodes = [CDUtilities.dyldSharedCacheImageRootNode, CDUtilities.otherImageRootNode]

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

                let classList = CDUtilities.classNames()
                let protocolList = CDUtilities.protocolNames()

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

extension RuntimeListings {
    enum RequestError: Error {
        case senderConnectionIsLose
    }

    private func request<T>(local: () throws -> T, remote: (_ senderConnection: XPCConnection) async throws -> T) async throws -> T {
        switch source {
        case .native:
            return try local()
        #if os(macOS)
        case let .macCatalyst(isSender):
            if isSender {
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
            imageList.contains(CDUtilities.patchImagePathForDyld(path))
        } remote: {
            #if os(macOS)
            return try await $0.sendMessage(name: ListingsCommandSet.isImageLoaded, request: path)
            #else
            fatalError()
            #endif
        }
    }

    public func loadImage(at path: String) async throws {
        try await request {
            try CDUtilities.loadImage(at: path)
        } remote: {
            #if os(macOS)
            try await $0.sendMessage(name: ListingsCommandSet.isImageLoaded, request: path)
            #endif
        }
    }

    public func classNamesIn(image: String) async throws -> [String] {
        try await request {
            CDUtilities.classNamesIn(image: image)
        } remote: {
            #if os(macOS)
            return try await $0.sendMessage(name: ListingsCommandSet.classNamesInImage, request: image)
            #else
            fatalError()
            #endif
        }
    }

    public func patchImagePathForDyld(_ imagePath: String) async throws -> String {
        try await request {
            CDUtilities.patchImagePathForDyld(imagePath)
        } remote: {
            #if os(macOS)
            return try await $0.sendMessage(name: ListingsCommandSet.patchImagePathForDyld, request: imagePath)
            #else
            fatalError()
            #endif
        }
    }

    public func imageName(ofClass className: String) async throws -> String? {
        try await request {
            CDUtilities.imageName(ofClass: className)
        } remote: {
            #if os(macOS)
            return try await $0.sendMessage(name: ListingsCommandSet.imageNameOfClassName, request: className)
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
            let semanticStringData: Data? = try await $0.sendMessage(name: ListingsCommandSet.semanticStringForRuntimeObjectWithOptions, request: SemanticStringRequest(runtimeObject: runtimeObject, options: options))
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
            return try await $0.sendMessage(name: ListingsCommandSet.runtimeObjectHierarchy, request: runtimeObject)
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
            return try await $0.sendMessage(name: ListingsCommandSet.runtimeObjectInfo, request: runtimeObject)
            #else
            fatalError()
            #endif
        }
    }
}

extension RuntimeListings {
    fileprivate static func protocolImageTrackingFor(
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

extension CDUtilities {
    fileprivate class func imageNames() -> [String] {
        (0...)
            .lazy
            .map(_dyld_get_image_name)
            .prefix { $0 != nil }
            .compactMap { $0 }
            .map { String(cString: $0) }
    }

    fileprivate class func protocolNames() -> [String] {
        var protocolCount: UInt32 = 0
        guard let protocolList = objc_copyProtocolList(&protocolCount) else { return [] }

        let names = sequence(first: protocolList) { $0.successor() }
            .prefix(Int(protocolCount))
            .map { NSStringFromProtocol($0.pointee) }

        return names
    }

    fileprivate class func imageName(ofClass className: String) -> String? {
        class_getImageName(NSClassFromString(className)).map { String(cString: $0) }
    }

    fileprivate class func classNamesIn(image: String) -> [String] {
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

    fileprivate class func patchImagePathForDyld(_ imagePath: String) -> String {
        guard imagePath.starts(with: "/") else { return imagePath }
        let rootPath = ProcessInfo.processInfo.environment["DYLD_ROOT_PATH"]
        guard let rootPath else { return imagePath }
        return rootPath.appending(imagePath)
    }

    fileprivate class func loadImage(at path: String) throws {
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

    fileprivate class var dyldSharedCacheImageRootNode: RuntimeNamedNode {
        return .rootNode(for: dyldSharedCacheImagePaths(), name: "Dyld Shared Cache")
    }

    fileprivate class var otherImageRootNode: RuntimeNamedNode {
        let dyldSharedCacheImagePaths = dyldSharedCacheImagePaths()
        let allImagePaths = imageNames()
        let otherImagePaths = allImagePaths.filter { !dyldSharedCacheImagePaths.contains($0) }
        return .rootNode(for: otherImagePaths, name: "Others")
    }
}

public struct DlOpenError: Error {
    public let message: String?
}
