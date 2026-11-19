import Foundation
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import SwiftMCP

// MARK: - List Windows

/// A RuntimeViewer document window
@Schema
public struct MCPWindowInfo: Codable, Sendable {
    /// The stable window identifier used by all other tools
    public let identifier: String
    /// The display title of the window
    public let displayName: String?
    /// Whether this is the key (frontmost) window
    public let isKeyWindow: Bool
    /// The name of the currently selected type in the sidebar
    public let selectedTypeName: String?
    /// The image path of the currently selected type
    public let selectedTypeImagePath: String?
    /// The image name of the currently selected type
    public let selectedTypeImageName: String?

    public init(
        identifier: String,
        displayName: String?,
        isKeyWindow: Bool,
        selectedTypeName: String?,
        selectedTypeImagePath: String?,
        selectedTypeImageName: String?
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.isKeyWindow = isKeyWindow
        self.selectedTypeName = selectedTypeName
        self.selectedTypeImagePath = selectedTypeImagePath
        self.selectedTypeImageName = selectedTypeImageName
    }
}

@Schema
public struct MCPListWindowsResponse: Codable, Sendable {
    public let windows: [MCPWindowInfo]

    public init(windows: [MCPWindowInfo]) {
        self.windows = windows
    }
}

// MARK: - Selected Type

public struct MCPSelectedTypeRequest: Codable, Sendable {
    public let windowIdentifier: String

    public init(windowIdentifier: String) {
        self.windowIdentifier = windowIdentifier
    }
}

@Schema
public struct MCPSelectedTypeResponse: Codable, Sendable {
    /// The full path of the image (framework/dylib) containing this type
    public let imagePath: String?
    /// The short name of the image
    public let imageName: String?
    /// The internal type name (may be mangled for Swift types)
    public let typeName: String?
    /// The human-readable display name
    public let displayName: String?
    /// The kind of type (e.g. "Objective-C Class", "Swift Struct", "Swift Protocol")
    public let typeKind: String?
    /// The full generated interface text (ObjC @interface header or Swift declaration)
    public let interfaceText: String?

    public init(
        imagePath: String?,
        imageName: String?,
        typeName: String?,
        displayName: String?,
        typeKind: String?,
        interfaceText: String?
    ) {
        self.imagePath = imagePath
        self.imageName = imageName
        self.typeName = typeName
        self.displayName = displayName
        self.typeKind = typeKind
        self.interfaceText = interfaceText
    }
}

// MARK: - Type Interface

public struct MCPTypeInterfaceRequest: Codable, Sendable {
    public let windowIdentifier: String
    public let imagePath: String?
    public let imageName: String?
    public let typeName: String

    public init(windowIdentifier: String, imagePath: String?, imageName: String? = nil, typeName: String) {
        self.windowIdentifier = windowIdentifier
        self.imagePath = imagePath
        self.imageName = imageName
        self.typeName = typeName
    }
}

@Schema
public struct MCPTypeInterfaceResponse: Codable, Sendable {
    /// The full path of the image (framework/dylib) containing this type
    public let imagePath: String?
    /// The short name of the image
    public let imageName: String?
    /// The internal type name (may be mangled for Swift types)
    public let typeName: String?
    /// The human-readable display name
    public let displayName: String?
    /// The kind of type (e.g. "Objective-C Class", "Swift Struct", "Swift Protocol")
    public let typeKind: String?
    /// The full generated interface text (ObjC @interface header or Swift declaration)
    public let interfaceText: String?
    /// Error message if the operation failed
    public let error: String?

    public init(
        imagePath: String?,
        imageName: String?,
        typeName: String?,
        displayName: String?,
        typeKind: String?,
        interfaceText: String?,
        error: String?
    ) {
        self.imagePath = imagePath
        self.imageName = imageName
        self.typeName = typeName
        self.displayName = displayName
        self.typeKind = typeKind
        self.interfaceText = interfaceText
        self.error = error
    }
}

// MARK: - Shared Data Types

/// Summary information about a runtime type
@Schema
public struct MCPRuntimeTypeInfo: Codable, Sendable {
    /// The internal type name
    public let name: String
    /// The human-readable display name
    public let displayName: String
    /// The kind of type (e.g. "Objective-C Class", "Swift Struct", "Swift Protocol")
    public let kind: String
    /// The full image path
    public let imagePath: String
    /// The short image name
    public let imageName: String

    public init(name: String, displayName: String, kind: String, imagePath: String, imageName: String) {
        self.name = name
        self.displayName = displayName
        self.kind = kind
        self.imagePath = imagePath
        self.imageName = imageName
    }

    public init(from object: RuntimeObject) {
        self.name = object.name
        self.displayName = object.displayName
        self.kind = object.kind.description
        self.imagePath = object.imagePath
        self.imageName = object.imageName
    }
}

public struct MCPGrepMatch: Codable, Sendable {
    public let typeName: String
    public let kind: String
    public let matchingLines: [String]

    public init(typeName: String, kind: String, matchingLines: [String]) {
        self.typeName = typeName
        self.kind = kind
        self.matchingLines = matchingLines
    }
}

// MARK: - List Types

public struct MCPListTypesRequest: Codable, Sendable {
    public let windowIdentifier: String
    public let imagePath: String?
    public let imageName: String?

    public init(windowIdentifier: String, imagePath: String?, imageName: String? = nil) {
        self.windowIdentifier = windowIdentifier
        self.imagePath = imagePath
        self.imageName = imageName
    }
}

/// List of runtime types in an image
@Schema
public struct MCPListTypesResponse: Codable, Sendable {
    /// The matching runtime types
    public let types: [MCPRuntimeTypeInfo]
    /// Error message if the operation failed
    public let error: String?

    public init(types: [MCPRuntimeTypeInfo], error: String?) {
        self.types = types
        self.error = error
    }
}

// MARK: - Search Types

public struct MCPSearchTypesRequest: Codable, Sendable {
    public let windowIdentifier: String
    public let query: String
    public let imagePath: String?
    public let imageName: String?

    public init(windowIdentifier: String, query: String, imagePath: String?, imageName: String? = nil) {
        self.windowIdentifier = windowIdentifier
        self.query = query
        self.imagePath = imagePath
        self.imageName = imageName
    }
}

/// Search results for runtime types
@Schema
public struct MCPSearchTypesResponse: Codable, Sendable {
    /// The matching runtime types
    public let types: [MCPRuntimeTypeInfo]
    /// Error message if the operation failed
    public let error: String?

    public init(types: [MCPRuntimeTypeInfo], error: String?) {
        self.types = types
        self.error = error
    }
}

// MARK: - Grep Type Interface

public struct MCPGrepTypeInterfaceRequest: Codable, Sendable {
    public let windowIdentifier: String
    public let imagePath: String?
    public let imageName: String?
    public let pattern: String

    public init(windowIdentifier: String, imagePath: String?, imageName: String? = nil, pattern: String) {
        self.windowIdentifier = windowIdentifier
        self.imagePath = imagePath
        self.imageName = imageName
        self.pattern = pattern
    }
}

public struct MCPGrepTypeInterfaceResponse: Codable, Sendable {
    public let matches: [MCPGrepMatch]
    public let error: String?

    public init(matches: [MCPGrepMatch], error: String?) {
        self.matches = matches
        self.error = error
    }
}

// MARK: - List Images

public struct MCPListImagesRequest: Codable, Sendable {
    public let windowIdentifier: String

    public init(windowIdentifier: String) {
        self.windowIdentifier = windowIdentifier
    }
}

/// List of image paths visible to the runtime
@Schema
public struct MCPListImagesResponse: Codable, Sendable {
    /// The full file system paths of all registered images
    public let imagePaths: [String]

    public init(imagePaths: [String]) {
        self.imagePaths = imagePaths
    }
}

// MARK: - Search Images

public struct MCPSearchImagesRequest: Codable, Sendable {
    public let windowIdentifier: String
    public let query: String

    public init(windowIdentifier: String, query: String) {
        self.windowIdentifier = windowIdentifier
        self.query = query
    }
}

/// Search results for image paths
@Schema
public struct MCPSearchImagesResponse: Codable, Sendable {
    /// The matching image paths
    public let imagePaths: [String]

    public init(imagePaths: [String]) {
        self.imagePaths = imagePaths
    }
}

// MARK: - Load Image

public struct MCPLoadImageRequest: Codable, Sendable {
    public let windowIdentifier: String
    public let imagePath: String
    public let loadObjects: Bool

    public init(windowIdentifier: String, imagePath: String, loadObjects: Bool = false) {
        self.windowIdentifier = windowIdentifier
        self.imagePath = imagePath
        self.loadObjects = loadObjects
    }
}

/// Result of an image loading operation
@Schema
public struct MCPLoadImageResponse: Codable, Sendable {
    /// The image path that was loaded
    public let imagePath: String
    /// Whether the image was already loaded before this call
    public let alreadyLoaded: Bool
    /// Whether objects have been enumerated
    public let objectsLoaded: Bool
    /// Error message if the operation failed
    public let error: String?

    public init(imagePath: String, alreadyLoaded: Bool, objectsLoaded: Bool, error: String?) {
        self.imagePath = imagePath
        self.alreadyLoaded = alreadyLoaded
        self.objectsLoaded = objectsLoaded
        self.error = error
    }
}

// MARK: - Is Image Loaded

public struct MCPIsImageLoadedRequest: Codable, Sendable {
    public let windowIdentifier: String
    public let imagePath: String

    public init(windowIdentifier: String, imagePath: String) {
        self.windowIdentifier = windowIdentifier
        self.imagePath = imagePath
    }
}

/// Result of an image status check
@Schema
public struct MCPIsImageLoadedResponse: Codable, Sendable {
    /// The image path that was checked
    public let imagePath: String
    /// Whether the image is loaded
    public let isLoaded: Bool

    public init(imagePath: String, isLoaded: Bool) {
        self.imagePath = imagePath
        self.isLoaded = isLoaded
    }
}

// MARK: - Load Objects

public struct MCPLoadObjectsRequest: Codable, Sendable {
    public let windowIdentifier: String
    public let imagePath: String

    public init(windowIdentifier: String, imagePath: String) {
        self.windowIdentifier = windowIdentifier
        self.imagePath = imagePath
    }
}

/// Result of an objects loading operation
@Schema
public struct MCPLoadObjectsResponse: Codable, Sendable {
    /// The image path that was loaded
    public let imagePath: String
    /// Whether the objects were already loaded before this call
    public let alreadyLoaded: Bool
    /// Number of types found
    public let objectCount: Int
    /// Error message if the operation failed
    public let error: String?

    public init(imagePath: String, alreadyLoaded: Bool, objectCount: Int, error: String?) {
        self.imagePath = imagePath
        self.alreadyLoaded = alreadyLoaded
        self.objectCount = objectCount
        self.error = error
    }
}

// MARK: - Is Objects Loaded

public struct MCPIsObjectsLoadedRequest: Codable, Sendable {
    public let windowIdentifier: String
    public let imagePath: String

    public init(windowIdentifier: String, imagePath: String) {
        self.windowIdentifier = windowIdentifier
        self.imagePath = imagePath
    }
}

/// Result of an objects status check
@Schema
public struct MCPIsObjectsLoadedResponse: Codable, Sendable {
    /// The image path that was checked
    public let imagePath: String
    /// Whether the objects are loaded
    public let isLoaded: Bool

    public init(imagePath: String, isLoaded: Bool) {
        self.imagePath = imagePath
        self.isLoaded = isLoaded
    }
}

// MARK: - Member Addresses

public struct MCPMemberAddressesRequest: Codable, Sendable {
    public let windowIdentifier: String
    public let imagePath: String?
    public let imageName: String?
    public let typeName: String
    public let memberName: String?

    public init(windowIdentifier: String, imagePath: String?, imageName: String? = nil, typeName: String, memberName: String?) {
        self.windowIdentifier = windowIdentifier
        self.imagePath = imagePath
        self.imageName = imageName
        self.typeName = typeName
        self.memberName = memberName
    }
}

/// A runtime member's address information
@Schema
public struct MCPMemberAddressInfo: Codable, Sendable {
    /// The demangled/readable member name
    public let name: String
    /// The member kind (e.g. method, property)
    public let kind: String
    /// The linker symbol name
    public let symbolName: String
    /// The hex memory address
    public let address: String

    public init(name: String, kind: String, symbolName: String, address: String) {
        self.name = name
        self.kind = kind
        self.symbolName = symbolName
        self.address = address
    }

    public init(from member: RuntimeMemberAddress) {
        self.name = member.name
        self.kind = member.kind
        self.symbolName = member.symbolName
        self.address = member.address
    }
}

/// Runtime memory addresses of a type's members
@Schema
public struct MCPMemberAddressesResponse: Codable, Sendable {
    /// The type name that was inspected
    public let typeName: String?
    /// The member address entries
    public let members: [MCPMemberAddressInfo]
    /// Error message if the operation failed
    public let error: String?

    public init(typeName: String?, members: [MCPMemberAddressInfo], error: String?) {
        self.typeName = typeName
        self.members = members
        self.error = error
    }
}

// MARK: - Cross References

/// One reference: the fields of the command line's `--json` rows
/// (`RuntimeCrossReferenceRow`), every address a hexadecimal string.
@Schema
public struct MCPCrossReferenceInfo: Codable, Sendable {
    /// The image of the referencing function
    public let imagePath: String
    /// Its file name without extension
    public let imageName: String
    /// The referencing function's first instruction, unslid
    public let functionAddress: String
    /// The referencing function's name, when anything names it
    public let functionName: String?
    /// The symbol the name came from
    public let functionSymbol: String?
    /// The referencing instruction, unslid
    public let instructionAddress: String
    /// call, tailCall, messageSend, superMessageSend, typeReference or indirectCall
    public let kind: String
    /// function, importedSymbol, selector, type, indirect or unrecognizedCode
    public let targetKind: String
    /// What is referenced, in words
    public let target: String
    /// exact, matchedBySelector or candidate
    public let precision: String
    /// A retain, release or other runtime helper call
    public let isRuntimeHelperCall: Bool

    public init(_ row: RuntimeCrossReferenceRow) {
        self.imagePath = row.imagePath
        self.imageName = row.imageName
        self.functionAddress = row.functionAddress
        self.functionName = row.functionName
        self.functionSymbol = row.functionSymbol
        self.instructionAddress = row.instructionAddress
        self.kind = row.kind
        self.targetKind = row.targetKind
        self.target = row.target
        self.precision = row.precision
        self.isRuntimeHelperCall = row.isRuntimeHelperCall
    }
}

/// The references a Callers, Callees or TypeReferences call found
@Schema
public struct MCPCrossReferencesResponse: Codable, Sendable {
    /// What was asked about, as resolved
    public let subject: String?
    /// Callers in image order, then by address; callees in instruction order
    public let references: [MCPCrossReferenceInfo]
    /// False when the limit was reached, or the call stopped waiting
    public let isComplete: Bool
    /// Why the result is incomplete, and what to do about it
    public let note: String?
    /// Error message if the operation failed
    public let error: String?

    public init(subject: String?, references: [MCPCrossReferenceInfo], isComplete: Bool, note: String?, error: String?) {
        self.subject = subject
        self.references = references
        self.isComplete = isComplete
        self.note = note
        self.error = error
    }
}

/// One symbolicated address: the fields of the command line's `--json`
/// rows (`RuntimeAddressSymbolicationRow`)
@Schema
public struct MCPAddressSymbolicationInfo: Codable, Sendable {
    /// The address asked about, unslid
    public let address: String
    public let imagePath: String?
    public let imageName: String?
    public let segmentName: String?
    public let sectionName: String?
    /// function, stub, pointerSlot, cString, constantString, symbol, data or unmapped
    public let kind: String
    /// The function the address lies in, when it lies in one
    public let functionAddress: String?
    public let functionName: String?
    /// How far into the function, or past the symbol
    public let offset: String?
    /// What lies there, in words
    public let summary: String

    public init(_ row: RuntimeAddressSymbolicationRow) {
        self.address = row.address
        self.imagePath = row.imagePath
        self.imageName = row.imageName
        self.segmentName = row.segmentName
        self.sectionName = row.sectionName
        self.kind = row.kind
        self.functionAddress = row.functionAddress
        self.functionName = row.functionName
        self.offset = row.offset
        self.summary = row.summary
    }
}

/// What each address a Symbolicate call named is
@Schema
public struct MCPSymbolicateResponse: Codable, Sendable {
    /// In the order the addresses were given
    public let symbolications: [MCPAddressSymbolicationInfo]

    public init(symbolications: [MCPAddressSymbolicationInfo]) {
        self.symbolications = symbolications
    }
}
