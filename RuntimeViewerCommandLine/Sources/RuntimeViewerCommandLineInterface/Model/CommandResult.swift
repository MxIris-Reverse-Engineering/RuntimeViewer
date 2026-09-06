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
    case sources(SourcesResult)
    case attached(AttachResult)
    case detached(DetachResult)
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
        case .sources(let result): return result
        case .attached(let result): return result
        case .detached(let result): return result
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

// MARK: - Sources

/// What kind of runtime source an engine is, derived from its `RuntimeSource`.
public enum SourceKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// The host process's own runtime.
    case local
    /// The Mac Catalyst runtime, served by the Catalyst helper.
    case macCatalyst
    /// A process this Mac injected into, reached over XPC.
    case attachedXPC
    /// A sandboxed process this Mac injected into, reached over a localhost socket.
    case attachedSocket
    /// A peer discovered over Bonjour and connected directly (an iOS device,
    /// a simulator payload, or a Mac without engine sharing).
    case bonjour
    /// An engine another RuntimeViewer forwards to this one.
    case mirrored
}

/// One runtime source the host can serve.
public struct SourceInfo: Codable, Sendable, Hashable {
    public let engineIdentifier: String
    public let displayName: String
    public let kind: SourceKind
    /// A value that can be passed straight back to `--source`.
    public let selector: SourceSelector
    /// The stable identity the app files bookmarks under; `nil` for engines
    /// that have none.
    public let stableIdentity: String?
    /// Whether the engine is connected and answering.
    public let isConnected: Bool

    public init(engineIdentifier: String, displayName: String, kind: SourceKind, selector: SourceSelector, stableIdentity: String?, isConnected: Bool) {
        self.engineIdentifier = engineIdentifier
        self.displayName = displayName
        self.kind = kind
        self.selector = selector
        self.stableIdentity = stableIdentity
        self.isConnected = isConnected
    }
}

/// The sources of one host (this Mac, a device, a peer), grouped the way the
/// app's source switcher groups them.
public struct SourceHost: Codable, Sendable, Hashable {
    public let hostIdentifier: String
    public let hostName: String
    public let sources: [SourceInfo]

    public init(hostIdentifier: String, hostName: String, sources: [SourceInfo]) {
        self.hostIdentifier = hostIdentifier
        self.hostName = hostName
        self.sources = sources
    }
}

public struct SourcesResult: Codable, Sendable, Hashable {
    public let hosts: [SourceHost]

    public init(hosts: [SourceHost]) {
        self.hosts = hosts
    }

    public var sources: [SourceInfo] {
        hosts.flatMap(\.sources)
    }
}

public struct AttachResult: Codable, Sendable, Hashable {
    public let processName: String
    public let processIdentifier: Int32
    /// `xpc`, `localSocket` or `simulatorBonjour`.
    public let transport: String
    /// The payload slice that was injected, e.g. `macOS` or `iOS Simulator`.
    public let payloadPlatform: String
    /// The selector that now reaches the process: `pid:<n>` for a Mac process,
    /// `engine:<id>` for a simulator process (it connects back over Bonjour and
    /// its identifier is `{deviceID}-{pid}`, which a pid alone cannot name).
    public let selector: SourceSelector
    public let engineIdentifier: String
    /// The process was attached before this command; nothing was injected.
    public let wasAlreadyAttached: Bool

    public init(processName: String, processIdentifier: Int32, transport: String, payloadPlatform: String, selector: SourceSelector, engineIdentifier: String, wasAlreadyAttached: Bool) {
        self.processName = processName
        self.processIdentifier = processIdentifier
        self.transport = transport
        self.payloadPlatform = payloadPlatform
        self.selector = selector
        self.engineIdentifier = engineIdentifier
        self.wasAlreadyAttached = wasAlreadyAttached
    }
}

public struct DetachResult: Codable, Sendable, Hashable {
    public let selector: SourceSelector
    public let engineIdentifier: String
    public let displayName: String
    public let kind: SourceKind

    public init(selector: SourceSelector, engineIdentifier: String, displayName: String, kind: SourceKind) {
        self.selector = selector
        self.engineIdentifier = engineIdentifier
        self.displayName = displayName
        self.kind = kind
    }
}
