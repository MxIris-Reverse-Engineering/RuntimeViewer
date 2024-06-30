import Foundation
import Combine
import ClassDumpRuntime
import MachO.dyld
import OSLog
#if os(macOS)
import RuntimeViewerService
import SwiftyXPC
#endif

public enum RuntimeSource {
    case native
    @available(iOS, unavailable)
    @available(tvOS, unavailable)
    @available(watchOS, unavailable)
    @available(visionOS, unavailable)
    case macCatalyst(isSender: Bool)
}

struct RuntimeInfo: Codable, Hashable {
    public var classList: [String]
    public var protocolList: [String]
    public var imageList: [String]
    public var protocolToImage: [String: String]
    public var imageToProtocols: [String: [String]]
}

public final class RuntimeListings {
    public static let shared = RuntimeListings()

    private static var sharedIfExists: RuntimeListings?

    private static let logger = Logger(subsystem: "com.JH.RuntimeViewerCore", category: "RuntimeListings")

    @Published public private(set) var classList: [String] = [] {
        didSet {
            #if os(macOS)
            if case let .macCatalyst(isSender) = source, isSender, let receiverConnection {
                Task {
                    do {
                        try await receiverConnection.sendMessage(name: ListingsCommandSet.classList, request: classList)
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
            if case let .macCatalyst(isSender) = source, isSender, let receiverConnection {
                Task {
                    do {
                        try await receiverConnection.sendMessage(name: ListingsCommandSet.protocolList, request: protocolList)
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
            if case let .macCatalyst(isSender) = source, isSender, let receiverConnection {
                Task {
                    do {
                        try await receiverConnection.sendMessage(name: ListingsCommandSet.imageList, request: imageList)
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
            if case let .macCatalyst(isSender) = source, isSender, let receiverConnection {
                Task {
                    do {
                        try await receiverConnection.sendMessage(name: ListingsCommandSet.protocolToImage, request: protocolToImage)
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
            if case let .macCatalyst(isSender) = source, isSender, let receiverConnection {
                Task {
                    do {
                        try await receiverConnection.sendMessage(name: ListingsCommandSet.imageToProtocols, request: imageToProtocols)
                    } catch {
                        Self.logger.error("\(error)")
                    }
                }
            }
            #endif
        }
    }

    @Published public private(set) var dyldSharedCacheImageNodes: [RuntimeNamedNode] = [] {
        didSet {
            #if os(macOS)
            if case let .macCatalyst(isSender) = source, isSender, let receiverConnection {
                Task {
                    do {
                        try await receiverConnection.sendMessage(name: ListingsCommandSet.dyldSharedCacheImageNodes, request: CDUtilities.dyldSharedCacheImagePaths())
                    } catch {
                        Self.logger.error("\(error)")
                    }
                }
            }
            #endif
        }
    }

    private enum ListingsCommandSet {
        static let classList = "com.JH.RuntimeViewer.RuntimeListings.classList"
        static let protocolList = "com.JH.RuntimeViewer.RuntimeListings.protocolList"
        static let imageList = "com.JH.RuntimeViewer.RuntimeListings.imageList"
        static let protocolToImage = "com.JH.RuntimeViewer.RuntimeListings.protocolToImage"
        static let imageToProtocols = "com.JH.RuntimeViewer.RuntimeListings.imageToProtocols"
        static let loadImage = "com.JH.RuntimeViewer.RuntimeListings.loadImage"
        static let senderLaunched = "com.JH.RuntimeViewer.RuntimeListings.senderLaunched"
        static let isImageLoaded = "com.JH.RuntimeViewer.RuntimeListings.isImageLoaded"
        static let classNamesInImage = "com.JH.RuntimeViewer.RuntimeListings.classNamesInImage"
        static let patchImagePathForDyld = "com.JH.RuntimeViewer.RuntimeListings.patchImagePathForDyld"
        static let semanticStringForRuntimeObjectWithOptions = "com.JH.RuntimeViewer.RuntimeListings.semanticStringForRuntimeObjectWithOptions"
        static let dyldSharedCacheImageNodes = "com.JH.RuntimeViewer.RuntimeListings.dyldSharedCacheImageNodes"
        static let runtimeObjectHierarchy = "com.JH.RuntimeViewer.RuntimeListings.runtimeObjectHierarchy"
    }

    private let shouldReload = PassthroughSubject<Void, Never>()

    private var subscriptions: Set<AnyCancellable> = []
    #if os(macOS)
    private var senderListener: SwiftyXPC.XPCListener?

    private var receiverListener: SwiftyXPC.XPCListener?

    private var serviceConnection: SwiftyXPC.XPCConnection?

    private var receiverConnection: SwiftyXPC.XPCConnection?

    private var senderConnection: SwiftyXPC.XPCConnection?
    #endif
    private let source: RuntimeSource

    public init(source: RuntimeSource = .native) {
        self.source = source
        switch source {
        case .native:
            observeRuntime()
        #if os(macOS)
        case let .macCatalyst(isSender):
            Task {
                do {
                    let serviceConnection = try XPCConnection(type: .remoteMachService(serviceName: RuntimeViewerService.serviceName, isPrivilegedHelperTool: true))
                    serviceConnection.activate()
                    self.serviceConnection = serviceConnection
                    let ping: String = try await serviceConnection.sendMessage(name: CommandSet.ping)
                    Self.logger.info("\(ping)")
                    let listener = try XPCListener(type: .anonymous, codeSigningRequirement: nil)
                    if isSender {
                        let endpoint: XPCEndpoint? = try await serviceConnection.sendMessage(name: CommandSet.fetchReceiverEndpoint)
                        if let endpoint {
                            let receiverConnection = try XPCConnection(type: .remoteServiceFromEndpoint(endpoint))
                            receiverConnection.activate()
                            self.receiverConnection = receiverConnection
                            try await serviceConnection.sendMessage(name: CommandSet.registerSenderEndpoint, request: listener.endpoint)
                            let ping: String = try await receiverConnection.sendMessage(name: CommandSet.ping)
                            Self.logger.info("\(ping)")
                            observeRuntime()
                        } else {
                            Self.logger.error("Fetch endpoint from machService failed.")
                        }

                        listener.setMessageHandler(name: CommandSet.ping) { connection in
                            return "Ping sender successfully."
                        }

                        listener.setMessageHandler(name: ListingsCommandSet.isImageLoaded) { [unowned self] (connection: XPCConnection, imagePath: String) -> Bool in
                            try await isImageLoaded(path: imagePath)
                        }

                        listener.setMessageHandler(name: ListingsCommandSet.loadImage) { [unowned self] (connection: XPCConnection, imagePath: String) in
                            try await loadImage(at: imagePath)
                        }

                        listener.setMessageHandler(name: ListingsCommandSet.classNamesInImage) { [unowned self] (connection: XPCConnection, image: String) -> [String] in
                            try await classNamesIn(image: image)
                        }

                        listener.setMessageHandler(name: ListingsCommandSet.patchImagePathForDyld) { [unowned self] (connection: XPCConnection, imagePath: String) -> String in
                            try await patchImagePathForDyld(imagePath)
                        }

                        listener.setMessageHandler(name: ListingsCommandSet.semanticStringForRuntimeObjectWithOptions) { [unowned self] (connection: XPCConnection, request: SemanticStringRequest) -> Data? in
                            let semanticString = try await semanticString(for: request.runtimeObject, options: request.options)
                            return try NSKeyedArchiver.archivedData(withRootObject: semanticString, requiringSecureCoding: true)
                        }

                        listener.activate()
                        self.senderListener = listener
                        try await receiverConnection?.sendMessage(name: ListingsCommandSet.senderLaunched)

                    } else {
                        listener.setMessageHandler(name: ListingsCommandSet.classList) { [unowned self] (connection: XPCConnection, classList: [String]) in
                            self.classList = classList
                        }

                        listener.setMessageHandler(name: ListingsCommandSet.protocolList) { [unowned self] (connection: XPCConnection, protocolList: [String]) in
                            self.protocolList = protocolList
                        }

                        listener.setMessageHandler(name: ListingsCommandSet.imageList) { [unowned self] (connection: XPCConnection, imageList: [String]) in
                            self.imageList = imageList
                        }

                        listener.setMessageHandler(name: ListingsCommandSet.protocolToImage) { [unowned self] (connection: XPCConnection, protocolToImage: [String: String]) in
                            self.protocolToImage = protocolToImage
                        }

                        listener.setMessageHandler(name: ListingsCommandSet.imageToProtocols) { [unowned self] (connection: XPCConnection, imageToProtocols: [String: [String]]) in
                            self.imageToProtocols = imageToProtocols
                        }

                        listener.setMessageHandler(name: ListingsCommandSet.dyldSharedCacheImageNodes) { [unowned self] (connection: XPCConnection, dyldSharedCacheImagePaths: [String]) in
                            self.dyldSharedCacheImageNodes = [CDUtilities.dyldSharedCacheImageRootNode(for: dyldSharedCacheImagePaths)]
                        }

                        listener.setMessageHandler(name: ListingsCommandSet.senderLaunched) { [unowned self] (connection: XPCConnection) in
                            let endpoint: XPCEndpoint? = try await serviceConnection.sendMessage(name: CommandSet.fetchSenderEndpoint)
                            if let endpoint {
                                let senderConnection = try XPCConnection(type: .remoteServiceFromEndpoint(endpoint))
                                senderConnection.activate()
                                self.senderConnection = senderConnection
                                let ping: String = try await senderConnection.sendMessage(name: CommandSet.ping)
                                Self.logger.info("\(ping)")
                            } else {
                                Self.logger.error("Fetch endpoint from machService failed.")
                            }
                        }

                        listener.setMessageHandler(name: CommandSet.ping) { connection in
                            return "Ping receiver successfully."
                        }

                        listener.activate()
                        self.receiverListener = listener
                        try await serviceConnection.sendMessage(name: CommandSet.registerReceiverEndpoint, request: listener.endpoint)
                    }
                } catch {
                    Self.logger.error("\(error)")
                }
            }
        #endif
        }
    }

    private func observeRuntime() {
        let classList = CDUtilities.classNames()
        let protocolList = CDUtilities.protocolNames()
        let imageList = CDUtilities.imageNames()
        self.classList = classList
        self.protocolList = protocolList
        self.imageList = imageList
        let (protocolToImage, imageToProtocols) = Self.protocolImageTrackingFor(
            protocolList: protocolList, protocolToImage: [:], imageToProtocols: [:]
        ) ?? ([:], [:])
        self.protocolToImage = protocolToImage
        self.imageToProtocols = imageToProtocols
        dyldSharedCacheImageNodes = [CDUtilities.dyldSharedCacheImageRootNode]

        RuntimeListings.sharedIfExists = self

        shouldReload
            .debounce(for: .milliseconds(15), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                Self.logger.debug("Start reload")
                self.classList = CDUtilities.classNames()
                self.protocolList = CDUtilities.protocolNames()
                self.imageList = CDUtilities.imageNames()
                Self.logger.debug("End reload")
            }
            .store(in: &subscriptions)

        _dyld_register_func_for_add_image { _, _ in
            RuntimeListings.sharedIfExists?.shouldReload.send()
        }

        _dyld_register_func_for_remove_image { _, _ in
            RuntimeListings.sharedIfExists?.shouldReload.send()
        }

        $protocolList
            .combineLatest($protocolToImage, $imageToProtocols)
            .sink { [unowned self] in
                guard let (protocolToImage, imageToProtocols) = Self.protocolImageTrackingFor(
                    protocolList: $0, protocolToImage: $1, imageToProtocols: $2
                ) else { return }
                self.protocolToImage = protocolToImage
                self.imageToProtocols = imageToProtocols
            }
            .store(in: &subscriptions)

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
extension RuntimeListings {
    private func request<T>(local: () throws -> T, remote: (_ senderConnection: XPCConnection) async throws -> T) async throws -> T {
        switch source {
        case .native:
            return try local()
        #if os(macOS)
        case let .macCatalyst(isSender):
            if isSender {
                return try local()
            } else {
                guard let senderConnection else { throw RequestError.senderConnectionIsLose }
                return try await remote(senderConnection)
            }
        #endif
        }
    }

    public func isImageLoaded(path: String) async throws -> Bool {
        try await request {
            imageList.contains(CDUtilities.patchImagePathForDyld(path))
        } remote: {
            #if os(macOS)
            try await $0.sendMessage(name: ListingsCommandSet.isImageLoaded, request: path)
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
            try await $0.sendMessage(name: ListingsCommandSet.classNamesInImage, request: image)
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
            try await $0.sendMessage(name: ListingsCommandSet.patchImagePathForDyld, request: imagePath)
            #else
            fatalError()
            #endif
        }
    }

    private struct SemanticStringRequest: Codable {
        let runtimeObject: RuntimeObjectType
        let options: CDGenerationOptions
    }

    public func semanticString(for runtimeObject: RuntimeObjectType, options: CDGenerationOptions) async throws -> CDSemanticString {
        enum NullError: Error {
            case objectIsNull
        }
        let semanticString = try await request {
            runtimeObject.semanticString(for: options)
        } remote: {
            #if os(macOS)
            let semanticStringData: Data? = try await $0.sendMessage(name: ListingsCommandSet.semanticStringForRuntimeObjectWithOptions, request: SemanticStringRequest(runtimeObject: runtimeObject, options: options))
            return try semanticStringData.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: CDSemanticString.self, from: $0) }
            #else
            fatalError()
            #endif
        }
        guard let semanticString else {
            throw NullError.objectIsNull
        }
        return semanticString
    }

    enum RequestError: Error {
        case senderConnectionIsLose
    }

    public func runtimeObjectHierarchy(_ runtimeObject: RuntimeObjectType) async throws -> [String] {
        try await request {
            runtimeObject.hierarchy()
        } remote: {
            #if os(macOS)
            try await $0.sendMessage(name: ListingsCommandSet.runtimeObjectHierarchy, request: runtimeObject)
            #else
            fatalError()
            #endif
        }
    }
}

extension RuntimeObjectType {
    fileprivate func semanticString(for options: CDGenerationOptions) -> CDSemanticString? {
        switch self {
        case let .class(named):
            if let cls = NSClassFromString(named) {
                let classModel = CDClassModel(with: cls)
                return classModel.semanticLines(with: options)
            } else {
                return nil
            }
        case let .protocol(named):
            if let proto = NSProtocolFromString(named) {
                let protocolModel = CDProtocolModel(with: proto)
                return protocolModel.semanticLines(with: options)
            } else {
                return nil
            }
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
        return dyldSharedCacheImageRootNode(for: CDUtilities.dyldSharedCacheImagePaths())
    }

    fileprivate class func dyldSharedCacheImageRootNode(for imagePaths: [String]) -> RuntimeNamedNode {
        let root = RuntimeNamedNode("")
        for path in imagePaths {
            var current = root
            for pathComponent in path.split(separator: "/") {
                switch pathComponent {
                case ".":
                    break // current
                case "..":
                    if let parent = current.parent {
                        current = parent
                    }
                default:
                    current = current.child(named: String(pathComponent))
                }
            }
        }
        return root
    }
}

public struct DlOpenError: Error {
    public let message: String?
}
