import Foundation

/// What the host answers a ``Command`` with. One case per command family.
///
/// The payload of each case is also the document `--json` prints, so field
/// names follow the MCP response types (`name` / `displayName` / `kind` /
/// `imagePath` / `imageName`) and stay stable.
public enum CommandResult: Codable, Sendable, Hashable {
    case imageList(ImageListResult)
    case imageLoaded(LoadImageResult)
    case typeList(TypeListResult)
    case interface(InterfaceResult)
    case hierarchy(HierarchyResult)
    case relationships(RelationshipsResult)
    case memberAddresses(MemberAddressesResult)
    case specializationParameters(SpecializationParametersResult)
    case specialized(SpecializedInterfaceResult)
    case export(ExportResult)
    case hostStatus(HostStatusResult)
    case shutdownAcknowledged(ShutdownAcknowledgement)

    /// The case's payload, for JSON output.
    public var payload: any Encodable & Sendable {
        switch self {
        case .imageList(let result): return result
        case .imageLoaded(let result): return result
        case .typeList(let result): return result
        case .interface(let result): return result
        case .hierarchy(let result): return result
        case .relationships(let result): return result
        case .memberAddresses(let result): return result
        case .specializationParameters(let result): return result
        case .specialized(let result): return result
        case .export(let result): return result
        case .hostStatus(let result): return result
        case .shutdownAcknowledged(let result): return result
        }
    }
}

// MARK: - Shared shapes

/// Summary of a runtime type. Field names match `MCPRuntimeTypeInfo`.
public struct TypeInfo: Codable, Sendable, Hashable {
    public let name: String
    public let displayName: String
    public let kind: String
    public let imagePath: String
    public let imageName: String

    public init(name: String, displayName: String, kind: String, imagePath: String, imageName: String) {
        self.name = name
        self.displayName = displayName
        self.kind = kind
        self.imagePath = imagePath
        self.imageName = imageName
    }
}

public struct ImageInfo: Codable, Sendable, Hashable {
    public let path: String
    /// Last path component without extension.
    public let name: String
    /// Whether the engine has loaded and indexed the image.
    public let isLoaded: Bool

    public init(path: String, name: String, isLoaded: Bool) {
        self.path = path
        self.name = name
        self.isLoaded = isLoaded
    }
}

// MARK: - Result payloads

public struct ImageListResult: Codable, Sendable, Hashable {
    public let images: [ImageInfo]

    public init(images: [ImageInfo]) {
        self.images = images
    }
}

public struct LoadImageResult: Codable, Sendable, Hashable {
    public let imagePath: String
    public let imageName: String
    public let objectCount: Int
    /// The image was already mapped into the host before this command.
    public let wasAlreadyLoaded: Bool

    public init(imagePath: String, imageName: String, objectCount: Int, wasAlreadyLoaded: Bool) {
        self.imagePath = imagePath
        self.imageName = imageName
        self.objectCount = objectCount
        self.wasAlreadyLoaded = wasAlreadyLoaded
    }
}

public struct TypeListResult: Codable, Sendable, Hashable {
    /// The images that were searched.
    public let imagePaths: [String]
    public let types: [TypeInfo]

    public init(imagePaths: [String], types: [TypeInfo]) {
        self.imagePaths = imagePaths
        self.types = types
    }
}

public struct InterfaceResult: Codable, Sendable, Hashable {
    public let typeInfo: TypeInfo
    public let interfaceText: String

    public init(typeInfo: TypeInfo, interfaceText: String) {
        self.typeInfo = typeInfo
        self.interfaceText = interfaceText
    }
}

public struct HierarchyResult: Codable, Sendable, Hashable {
    public let typeInfo: TypeInfo
    /// From the type itself up to the root, as the engine reports it.
    public let hierarchy: [String]

    public init(typeInfo: TypeInfo, hierarchy: [String]) {
        self.typeInfo = typeInfo
        self.hierarchy = hierarchy
    }
}

public struct RelationshipsResult: Codable, Sendable, Hashable {
    public let typeInfo: TypeInfo
    public let subclasses: [TypeInfo]
    public let conformingTypes: [TypeInfo]

    public init(typeInfo: TypeInfo, subclasses: [TypeInfo], conformingTypes: [TypeInfo]) {
        self.typeInfo = typeInfo
        self.subclasses = subclasses
        self.conformingTypes = conformingTypes
    }
}

public struct MemberAddress: Codable, Sendable, Hashable {
    public let name: String
    public let kind: String
    public let symbolName: String
    public let address: String

    public init(name: String, kind: String, symbolName: String, address: String) {
        self.name = name
        self.kind = kind
        self.symbolName = symbolName
        self.address = address
    }
}

public struct MemberAddressesResult: Codable, Sendable, Hashable {
    public let typeInfo: TypeInfo
    public let members: [MemberAddress]

    public init(typeInfo: TypeInfo, members: [MemberAddress]) {
        self.typeInfo = typeInfo
        self.members = members
    }
}

public struct SpecializationCandidate: Codable, Sendable, Hashable {
    public let displayName: String
    public let imagePath: String
    public let imageName: String
    public let kind: String
    public let isGeneric: Bool

    public init(displayName: String, imagePath: String, imageName: String, kind: String, isGeneric: Bool) {
        self.displayName = displayName
        self.imagePath = imagePath
        self.imageName = imageName
        self.kind = kind
        self.isGeneric = isGeneric
    }
}

public struct SpecializationParameter: Codable, Sendable, Hashable {
    public let name: String
    public let displayDescription: String
    public let candidates: [SpecializationCandidate]

    public init(name: String, displayDescription: String, candidates: [SpecializationCandidate]) {
        self.name = name
        self.displayDescription = displayDescription
        self.candidates = candidates
    }
}

public struct SpecializationParametersResult: Codable, Sendable, Hashable {
    public let typeInfo: TypeInfo
    public let parameters: [SpecializationParameter]

    public init(typeInfo: TypeInfo, parameters: [SpecializationParameter]) {
        self.typeInfo = typeInfo
        self.parameters = parameters
    }
}

public struct SpecializedInterfaceResult: Codable, Sendable, Hashable {
    /// The specialized type the engine registered.
    public let typeInfo: TypeInfo
    public let interfaceText: String
    /// Preflight warnings that did not block the specialization.
    public let warnings: [String]

    public init(typeInfo: TypeInfo, interfaceText: String, warnings: [String]) {
        self.typeInfo = typeInfo
        self.interfaceText = interfaceText
        self.warnings = warnings
    }
}

public struct ExportResult: Codable, Sendable, Hashable {
    public let imagePath: String
    public let imageName: String
    public let outputDirectory: String
    public let succeeded: Int
    public let failed: Int
    public let objcCount: Int
    public let swiftCount: Int
    public let totalDuration: TimeInterval

    public init(imagePath: String, imageName: String, outputDirectory: String, succeeded: Int, failed: Int, objcCount: Int, swiftCount: Int, totalDuration: TimeInterval) {
        self.imagePath = imagePath
        self.imageName = imageName
        self.outputDirectory = outputDirectory
        self.succeeded = succeeded
        self.failed = failed
        self.objcCount = objcCount
        self.swiftCount = swiftCount
        self.totalDuration = totalDuration
    }
}

public struct HostStatusResult: Codable, Sendable, Hashable {
    public let processIdentifier: Int32
    public let kind: HostKind
    public let version: String
    public let protocolVersion: Int
    public let startedAt: Date
    public let activeConnections: Int
    public let inFlightCommands: Int
    /// Seconds of idleness before the host exits; `nil` when it never exits on its own.
    public let idleTimeout: TimeInterval?
    public let isShuttingDown: Bool
    public let loadedImagePaths: [String]

    public init(processIdentifier: Int32, kind: HostKind, version: String, protocolVersion: Int, startedAt: Date, activeConnections: Int, inFlightCommands: Int, idleTimeout: TimeInterval?, isShuttingDown: Bool, loadedImagePaths: [String]) {
        self.processIdentifier = processIdentifier
        self.kind = kind
        self.version = version
        self.protocolVersion = protocolVersion
        self.startedAt = startedAt
        self.activeConnections = activeConnections
        self.inFlightCommands = inFlightCommands
        self.idleTimeout = idleTimeout
        self.isShuttingDown = isShuttingDown
        self.loadedImagePaths = loadedImagePaths
    }
}

public struct ShutdownAcknowledgement: Codable, Sendable, Hashable {
    public let reason: ShutdownReason
    public let processIdentifier: Int32

    public init(reason: ShutdownReason, processIdentifier: Int32) {
        self.reason = reason
        self.processIdentifier = processIdentifier
    }
}
