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

public enum RuntimeSource {
    case native
    @available(iOS, unavailable)
    @available(tvOS, unavailable)
    @available(watchOS, unavailable)
    @available(visionOS, unavailable)
    case macCatalyst
}

public final class RuntimeListings: ObservableObject {
    public static let shared = RuntimeListings()
    private static var sharedIfExists: RuntimeListings?
    private static let logger = Logger(subsystem: "null.leptos.HeaderViewer", category: "RuntimeListings")

    @Published public private(set) var classList: [String]
    @Published public private(set) var protocolList: [String]
    @Published public private(set) var imageList: [String]

    @Published public private(set) var protocolToImage: [String: String]
    @Published public private(set) var imageToProtocols: [String: [String]]

    private let shouldReload = PassthroughSubject<Void, Never>()

    private var subscriptions: Set<AnyCancellable> = []

    public init(source: RuntimeSource = .native) {
        let classList = CDUtilities.classNames()
        let protocolList = CDUtilities.protocolNames()
        self.classList = classList
        self.protocolList = protocolList
        self.imageList = CDUtilities.imageNames()

        let (protocolToImage, imageToProtocols) = Self.protocolImageTrackingFor(
            protocolList: protocolList, protocolToImage: [:], imageToProtocols: [:]
        ) ?? ([:], [:])
        self.protocolToImage = protocolToImage
        self.imageToProtocols = imageToProtocols

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
}

extension RuntimeListings {
    public static func protocolImageTrackingFor(
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
    public class func imageNames() -> [String] {
        (0...)
            .lazy
            .map(_dyld_get_image_name)
            .prefix { $0 != nil }
            .compactMap { $0 }
            .map { String(cString: $0) }
    }

    public class func protocolNames() -> [String] {
        var protocolCount: UInt32 = 0
        guard let protocolList = objc_copyProtocolList(&protocolCount) else { return [] }

        let names = sequence(first: protocolList) { $0.successor() }
            .prefix(Int(protocolCount))
            .map { NSStringFromProtocol($0.pointee) }

        return names
    }

    public class func classNamesIn(image: String) -> [String] {
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
    public class func patchImagePathForDyld(_ imagePath: String) -> String {
        guard imagePath.starts(with: "/") else { return imagePath }
        let rootPath = ProcessInfo.processInfo.environment["DYLD_ROOT_PATH"]
        guard let rootPath else { return imagePath }
        return rootPath.appending(imagePath)
    }

    public class func loadImage(at path: String) throws {
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
    public class var dyldSharedCacheImageRootNode: RuntimeNamedNode {
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
