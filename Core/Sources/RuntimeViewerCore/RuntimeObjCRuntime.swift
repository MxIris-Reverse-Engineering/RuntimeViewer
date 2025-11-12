import Foundation
import Combine

final class RuntimeObjCRuntime {
    @Published private var protocolList: [String] = []

    @Published private var protocolToImage: [String: String] = [:]

    @Published private var imageToProtocols: [String: [String]] = [:]

    private var subscriptions: Set<AnyCancellable> = []

    init() {}

    func reloadData() {
        protocolList = Self.protocolNames()
        let (_protocolToImage, _imageToProtocols) = Self.protocolImageTrackingFor(
            protocolList: protocolList, protocolToImage: [:], imageToProtocols: [:]
        ) ?? ([:], [:])
        protocolToImage = _protocolToImage
        imageToProtocols = _imageToProtocols
    }

    func classNames(in image: String, stripSwiftClass: Bool = true) -> [RuntimeObjectName] {
        var classNames = Self.classNames(inImage: image)
        if stripSwiftClass {
            classNames = classNames.filter { !Self.isSwiftClass(ofClassName: $0) }
        }
        return classNames.map { RuntimeObjectName(name: $0, displayName: $0, kind: .objc(.type(.class)), imagePath: image, children: []) }
    }

    private func classHierarchy(_ cls: AnyClass) -> [AnyClass] {
        var hierarcy = [AnyClass]()
        hierarcy.append(cls)
        var superclass: AnyClass? = class_getSuperclass(cls)
        while let currentSuperclass = superclass {
            hierarcy.append(currentSuperclass)
            superclass = class_getSuperclass(currentSuperclass)
        }

        return hierarcy
    }

    func protocolNames(in image: String) -> [RuntimeObjectName] {
        (imageToProtocols[image] ?? []).map { RuntimeObjectName(name: $0, displayName: $0, kind: .objc(.type(.protocol)), imagePath: image, children: []) }
    }

    func hierarchy(for name: RuntimeObjectName) -> [String] {
        switch name.kind {
        case .objc(.type(.class)):
            if let cls = NSClassFromString(name.name) {
                return classHierarchy(cls).map { NSStringFromClass($0) }
            } else {
                return []
            }
        case .objc(.type(.protocol)):
            if let proto = NSProtocolFromString(name.name) {
                return (CDProtocolModel(with: proto).protocols ?? []).map { $0.name }
            } else {
                return []
            }
        default:
            return []
        }
    }

    func interface(for runtimeObjectName: RuntimeObjectName, options: CDGenerationOptions) -> RuntimeObjectInterface? {
        switch runtimeObjectName.kind {
        case .objc(let kindOfObjC):
            switch kindOfObjC {
            case .type(let kind):
                switch kind {
                case .class:
                    if let cls = NSClassFromString(runtimeObjectName.name) {
                        let classModel = CDClassModel(with: cls)
                        return .init(name: runtimeObjectName, interfaceString: classModel.semanticLines(with: options).semanticString)
                    } else {
                        return nil
                    }
                case .protocol:
                    if let proto = NSProtocolFromString(runtimeObjectName.name) {
                        let protocolModel = CDProtocolModel(with: proto)
                        return .init(name: runtimeObjectName, interfaceString: protocolModel.semanticLines(with: options).semanticString)
                    } else {
                        return nil
                    }
                }
            default:
                break
            }
        default:
            break
        }
        return nil
    }

    static func classNames() -> [String] {
        CDUtilities.classNames()
    }

    static func protocolNames() -> [String] {
        var protocolCount: UInt32 = 0
        guard let protocolList = objc_copyProtocolList(&protocolCount) else { return [] }

        let names = sequence(first: protocolList) { $0.successor() }
            .prefix(Int(protocolCount))
            .map { NSStringFromProtocol($0.pointee) }

        return names
    }

    static func imageName(ofClass className: String) -> String? {
        class_getImageName(NSClassFromString(className)).map { String(cString: $0) }
    }

    static func classNames(inImage image: String) -> [String] {
        DyldUtilities.patchImagePathForDyld(image).withCString { cString in
            var classCount: UInt32 = 0
            guard let classNames = objc_copyClassNamesForImage(cString, &classCount) else { return [] }

            let names = sequence(first: classNames) { $0.successor() }
                .prefix(Int(classCount))
                .map { String(cString: $0.pointee) }

            classNames.deallocate()

            return names
        }
    }

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

    static func isSwiftClass(ofClassName className: String) -> Bool {
        struct objc_class {
            let isa: UInt
            let superclass: UInt
            let cache1: UInt
            let cache2: UInt
            let bits: UInt
        }

        guard let cls = NSClassFromString(className) else { return false }
        let objcClass = unsafeBitCast(cls, to: UnsafePointer<objc_class>.self).pointee

        return (objcClass.bits & 1) == 1 || (objcClass.bits & 2) == 2
    }
}
