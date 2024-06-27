//
//  RuntimeListings.swift
//  HeaderViewer
//
//  Created by Leptos on 2/20/24.
//

import Foundation
import Combine
import ClassDumpRuntime
import MachO.dyld
import OSLog
import RuntimeViewerService
import SwiftyXPC

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
            if case let .macCatalyst(isSender) = source, isSender, let receiverConnection {
                Task {
                    do {
                        try await receiverConnection.sendMessage(name: ListingsCommandSet.classList, request: classList)
                    } catch {
                        Self.logger.error("\(error)")
                    }
                }
            }
        }
    }

    @Published public private(set) var protocolList: [String] = [] {
        didSet {
            if case let .macCatalyst(isSender) = source, isSender, let receiverConnection {
                Task {
                    do {
                        try await receiverConnection.sendMessage(name: ListingsCommandSet.protocolList, request: protocolList)
                    } catch {
                        Self.logger.error("\(error)")
                    }
                }
            }
        }
    }

    @Published public private(set) var imageList: [String] = [] {
        didSet {
            if case let .macCatalyst(isSender) = source, isSender, let receiverConnection {
                Task {
                    do {
                        try await receiverConnection.sendMessage(name: ListingsCommandSet.imageList, request: imageList)
                    } catch {
                        Self.logger.error("\(error)")
                    }
                }
            }
        }
    }

    @Published public private(set) var protocolToImage: [String: String] = [:] {
        didSet {
            if case let .macCatalyst(isSender) = source, isSender, let receiverConnection {
                Task {
                    do {
                        try await receiverConnection.sendMessage(name: ListingsCommandSet.protocolToImage, request: protocolToImage)
                    } catch {
                        Self.logger.error("\(error)")
                    }
                }
            }
        }
    }

    @Published public private(set) var imageToProtocols: [String: [String]] = [:] {
        didSet {
            if case let .macCatalyst(isSender) = source, isSender, let receiverConnection {
                Task {
                    do {
                        try await receiverConnection.sendMessage(name: ListingsCommandSet.imageToProtocols, request: imageToProtocols)
                    } catch {
                        Self.logger.error("\(error)")
                    }
                }
            }
        }
    }

    @Published public private(set) var dyldSharedCacheImageNodes: [RuntimeNamedNode] = []
    
    enum ListingsCommandSet {
        static let classList = "com.JH.RuntimeViewer.RuntimeListings.classList"
        static let protocolList = "com.JH.RuntimeViewer.RuntimeListings.protocolList"
        static let imageList = "com.JH.RuntimeViewer.RuntimeListings.imageList"
        static let protocolToImage = "com.JH.RuntimeViewer.RuntimeListings.protocolToImage"
        static let imageToProtocols = "com.JH.RuntimeViewer.RuntimeListings.imageToProtocols"
        static let loadImage = "com.JH.RuntimeViewer.RuntimeListings.loadImage"
        static let senderLaunched = "com.JH.RuntimeViewer.RuntimeListings.senderLaunched"
        static let classNamesInImage = "com.JH.RuntimeViewer.RuntimeListings.classNamesInImage"
        static let patchImagePathForDyld = "com.JH.RuntimeViewer.RuntimeListings.patchImagePathForDyld"
    }

    private let shouldReload = PassthroughSubject<Void, Never>()

    private var subscriptions: Set<AnyCancellable> = []

    private var senderListener: SwiftyXPC.XPCListener?

    private var receiverListener: SwiftyXPC.XPCListener?

    private var serviceConnection: SwiftyXPC.XPCConnection?

    private var receiverConnection: SwiftyXPC.XPCConnection?

    private var senderConnection: SwiftyXPC.XPCConnection?

    private let source: RuntimeSource

    public init(source: RuntimeSource = .native) {
        self.source = source
        switch source {
        case .native:
            observeRuntime()
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

                        listener.setMessageHandler(name: ListingsCommandSet.loadImage) { [unowned self] (connection: XPCConnection, imagePath: String) in
                            try await self.loadImage(at: imagePath)
                        }

                        listener.setMessageHandler(name: CommandSet.ping) { connection in
                            return "Ping sender successfully."
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
        self.dyldSharedCacheImageNodes = [CDUtilities.dyldSharedCacheImageRootNode]
        
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

    public func isImageLoaded(path: String) -> Bool {
        imageList.contains(CDUtilities.patchImagePathForDyld(path))
    }

    public func loadImage(at path: String) async throws {
        switch source {
        case .native:
            try CDUtilities.loadImage(at: path)
        case .macCatalyst(let isSender):
            if isSender {
                try CDUtilities.loadImage(at: path)
            } else {
                try await senderConnection?.sendMessage(name: ListingsCommandSet.loadImage, request: path)
            }
        }
    }
    
    public func classNamesIn(image: String) async throws -> [String] {
        switch source {
        case .native:
            return CDUtilities.classNamesIn(image: image)
        case .macCatalyst(let isSender):
            if isSender {
                return CDUtilities.classNamesIn(image: image)
            } else {
                return try await senderConnection?.sendMessage(name: ListingsCommandSet.classNamesInImage, request: image) ?? []
            }
        }
    }
    
    public func patchImagePathForDyld(_ imagePath: String) async throws -> String {
        switch source {
        case .native:
            return CDUtilities.patchImagePathForDyld(imagePath)
        case .macCatalyst(let isSender):
            if isSender {
                return CDUtilities.patchImagePathForDyld(imagePath)
            } else {
                return try await senderConnection?.sendMessage(name: ListingsCommandSet.patchImagePathForDyld, request: imagePath) ?? ""
            }
        }
    }
}

extension RuntimeListings {
    static func protocolImageTrackingFor(
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
    class func imageNames() -> [String] {
        (0...)
            .lazy
            .map(_dyld_get_image_name)
            .prefix { $0 != nil }
            .compactMap { $0 }
            .map { String(cString: $0) }
    }

    class func protocolNames() -> [String] {
        var protocolCount: UInt32 = 0
        guard let protocolList = objc_copyProtocolList(&protocolCount) else { return [] }

        let names = sequence(first: protocolList) { $0.successor() }
            .prefix(Int(protocolCount))
            .map { NSStringFromProtocol($0.pointee) }

        return names
    }

    class func classNamesIn(image: String) -> [String] {
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
}

extension CDUtilities {
    class func patchImagePathForDyld(_ imagePath: String) -> String {
        guard imagePath.starts(with: "/") else { return imagePath }
        let rootPath = ProcessInfo.processInfo.environment["DYLD_ROOT_PATH"]
        guard let rootPath else { return imagePath }
        return rootPath.appending(imagePath)
    }

    class func loadImage(at path: String) throws {
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
}

public struct DlOpenError: Error {
    public let message: String?
}

extension CDUtilities {
    class var dyldSharedCacheImageRootNode: RuntimeNamedNode {
        let root = RuntimeNamedNode("")
        for path in CDUtilities.dyldSharedCacheImagePaths() {
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
