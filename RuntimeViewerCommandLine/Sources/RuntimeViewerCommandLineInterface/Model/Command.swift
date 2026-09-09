import Foundation

/// A request the client sends to the CLI host.
///
/// Every engine-backed command carries its own ``SourceSelector``; the two host
/// commands at the end are answered by the host itself and never reach an
/// engine.
public enum Command: Codable, Sendable, Hashable {
    case listImages(ListImagesCommand)
    case loadImage(LoadImageCommand)
    case listTypes(ListTypesCommand)
    case searchTypes(SearchTypesCommand)
    case interface(InterfaceCommand)
    case hierarchy(HierarchyCommand)
    case relationships(RelationshipsCommand)
    case memberAddresses(MemberAddressesCommand)
    case specialize(SpecializeCommand)
    case export(ExportCommand)
    case hostStatus
    case shutdownHost(ShutdownReason)
}

extension Command {
    /// Whether the client may re-send the command to a freshly started host
    /// after the connection dropped mid-flight.
    ///
    /// Everything that only reads, or that re-running leaves in the same state
    /// (`load`), is retried once. Export writes files and a shutdown must not
    /// be repeated against the host that replaced the one it stopped.
    public var isRetryable: Bool {
        switch self {
        case .export, .shutdownHost:
            return false
        case .listImages, .loadImage, .listTypes, .searchTypes, .interface, .hierarchy,
             .relationships, .memberAddresses, .specialize, .hostStatus:
            return true
        }
    }

    /// The source an engine-backed command targets; `nil` for host commands.
    public var source: SourceSelector? {
        switch self {
        case .listImages(let command): return command.source
        case .loadImage(let command): return command.source
        case .listTypes(let command): return command.source
        case .searchTypes(let command): return command.source
        case .interface(let command): return command.source
        case .hierarchy(let command): return command.source
        case .relationships(let command): return command.source
        case .memberAddresses(let command): return command.source
        case .specialize(let command): return command.source
        case .export(let command): return command.source
        case .hostStatus, .shutdownHost: return nil
        }
    }

    /// A short name for logs and progress lines.
    public var name: String {
        switch self {
        case .listImages: return "images"
        case .loadImage: return "load"
        case .listTypes: return "types"
        case .searchTypes: return "search"
        case .interface: return "interface"
        case .hierarchy: return "hierarchy"
        case .relationships: return "relationships"
        case .memberAddresses: return "members"
        case .specialize: return "specialize"
        case .export: return "export"
        case .hostStatus: return "host status"
        case .shutdownHost: return "host shutdown"
        }
    }
}

// MARK: - Shared option types

/// Which set of interface generation options a command uses.
public enum GenerationOptionsChoice: String, Codable, Sendable, Hashable, CaseIterable {
    /// The library defaults.
    case `default`
    /// Every comment and layout detail switched on (`GenerationOptions.mcp`).
    case full
    /// What the RuntimeViewer app currently has configured, read from its
    /// persisted options and settings. Falls back to the defaults when the app
    /// has never written them.
    case application = "app"
}

/// A filter on the kind of runtime object, as accepted by `--kind`.
public enum TypeKindFilter: String, Codable, Sendable, Hashable, CaseIterable {
    case objcClass = "objc-class"
    case objcProtocol = "objc-protocol"
    case objcCategory = "objc-category"
    case swiftClass = "swift-class"
    case swiftStruct = "swift-struct"
    case swiftEnum = "swift-enum"
    case swiftProtocol = "swift-protocol"
    case swiftTypeAlias = "swift-typealias"
    case swiftExtension = "swift-extension"
    case swiftConformance = "swift-conformance"
    case cStruct = "c-struct"
    case cUnion = "c-union"
}

/// How an export lays out one language's interfaces.
public enum ExportLayout: String, Codable, Sendable, Hashable, CaseIterable {
    /// One file per image: `<Image>.h` or `<Image>.swiftinterface`.
    case single
    /// One file per type under `ObjCHeaders/` or `SwiftInterfaces/`.
    case directory
}

/// Why a host was asked to shut down.
public enum ShutdownReason: String, Codable, Sendable, Hashable {
    /// `host stop` or `host restart`.
    case userRequest
    /// The RuntimeViewer app is starting and takes over as host.
    case applicationTakeover
}

// MARK: - Command payloads

public struct ListImagesCommand: Codable, Sendable, Hashable {
    public var source: SourceSelector
    /// Only images the engine has loaded and indexed.
    public var loadedOnly: Bool
    /// Case-insensitive substring the image path must contain.
    public var query: String?

    public init(source: SourceSelector = .local, loadedOnly: Bool = false, query: String? = nil) {
        self.source = source
        self.loadedOnly = loadedOnly
        self.query = query
    }
}

public struct LoadImageCommand: Codable, Sendable, Hashable {
    public var source: SourceSelector
    /// Absolute path of the image; the client resolves relative paths before sending.
    public var imagePath: String

    public init(source: SourceSelector = .local, imagePath: String) {
        self.source = source
        self.imagePath = imagePath
    }
}

public struct ListTypesCommand: Codable, Sendable, Hashable {
    public var source: SourceSelector
    /// An absolute path or a short image name; `nil` means every loaded image.
    public var image: String?
    /// Empty means every kind.
    public var kinds: [TypeKindFilter]

    public init(source: SourceSelector = .local, image: String? = nil, kinds: [TypeKindFilter] = []) {
        self.source = source
        self.image = image
        self.kinds = kinds
    }
}

public struct SearchTypesCommand: Codable, Sendable, Hashable {
    public var source: SourceSelector
    public var image: String?
    public var query: String
    public var isRegularExpression: Bool
    public var kinds: [TypeKindFilter]

    public init(source: SourceSelector = .local, image: String? = nil, query: String, isRegularExpression: Bool = false, kinds: [TypeKindFilter] = []) {
        self.source = source
        self.image = image
        self.query = query
        self.isRegularExpression = isRegularExpression
        self.kinds = kinds
    }
}

public struct InterfaceCommand: Codable, Sendable, Hashable {
    public var source: SourceSelector
    public var image: String?
    public var typeName: String
    public var options: GenerationOptionsChoice

    public init(source: SourceSelector = .local, image: String? = nil, typeName: String, options: GenerationOptionsChoice = .default) {
        self.source = source
        self.image = image
        self.typeName = typeName
        self.options = options
    }
}

public struct HierarchyCommand: Codable, Sendable, Hashable {
    public var source: SourceSelector
    public var image: String?
    public var typeName: String

    public init(source: SourceSelector = .local, image: String? = nil, typeName: String) {
        self.source = source
        self.image = image
        self.typeName = typeName
    }
}

public struct RelationshipsCommand: Codable, Sendable, Hashable {
    public var source: SourceSelector
    public var image: String?
    public var typeName: String

    public init(source: SourceSelector = .local, image: String? = nil, typeName: String) {
        self.source = source
        self.image = image
        self.typeName = typeName
    }
}

public struct MemberAddressesCommand: Codable, Sendable, Hashable {
    public var source: SourceSelector
    public var image: String?
    public var typeName: String
    /// Case-insensitive substring the member name must contain.
    public var memberName: String?

    public init(source: SourceSelector = .local, image: String? = nil, typeName: String, memberName: String? = nil) {
        self.source = source
        self.image = image
        self.typeName = typeName
        self.memberName = memberName
    }
}

public struct SpecializeCommand: Codable, Sendable, Hashable {
    public var source: SourceSelector
    public var image: String
    public var typeName: String
    /// Generic parameter name → candidate display name. Empty lists the parameters.
    public var arguments: [String: String]
    /// List the parameters and their candidates instead of specializing.
    public var listOnly: Bool
    public var options: GenerationOptionsChoice

    public init(source: SourceSelector = .local, image: String, typeName: String, arguments: [String: String] = [:], listOnly: Bool = false, options: GenerationOptionsChoice = .default) {
        self.source = source
        self.image = image
        self.typeName = typeName
        self.arguments = arguments
        self.listOnly = listOnly
        self.options = options
    }
}

public struct ExportCommand: Codable, Sendable, Hashable {
    public var source: SourceSelector
    public var image: String
    /// Absolute path; the client resolves relative paths before sending.
    public var outputDirectory: String
    public var objcLayout: ExportLayout
    public var swiftLayout: ExportLayout
    public var includeMetadata: Bool
    public var options: GenerationOptionsChoice

    public init(source: SourceSelector = .local, image: String, outputDirectory: String, objcLayout: ExportLayout = .single, swiftLayout: ExportLayout = .single, includeMetadata: Bool = true, options: GenerationOptionsChoice = .default) {
        self.source = source
        self.image = image
        self.outputDirectory = outputDirectory
        self.objcLayout = objcLayout
        self.swiftLayout = swiftLayout
        self.includeMetadata = includeMetadata
        self.options = options
    }
}
