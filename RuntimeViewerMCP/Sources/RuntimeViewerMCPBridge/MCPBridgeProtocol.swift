import Foundation
import RuntimeViewerCore

// MARK: - List Windows

public struct MCPWindowInfo: Codable, Sendable {
    public let identifier: String
    public let displayName: String?
    public let isKeyWindow: Bool
    public let selectedTypeName: String?
    public let selectedTypeImagePath: String?
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

public struct MCPSelectedTypeResponse: Codable, Sendable {
    public let imagePath: String?
    public let imageName: String?
    public let typeName: String?
    public let displayName: String?
    public let typeKind: String?
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

public struct MCPTypeInterfaceResponse: Codable, Sendable {
    public let imagePath: String?
    public let imageName: String?
    public let typeName: String?
    public let displayName: String?
    public let typeKind: String?
    public let interfaceText: String?
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

public struct MCPRuntimeTypeInfo: Codable, Sendable {
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

public struct MCPListTypesResponse: Codable, Sendable {
    public let types: [MCPRuntimeTypeInfo]
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

public struct MCPSearchTypesResponse: Codable, Sendable {
    public let types: [MCPRuntimeTypeInfo]
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

public struct MCPListImagesResponse: Codable, Sendable {
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

public struct MCPSearchImagesResponse: Codable, Sendable {
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

public struct MCPLoadImageResponse: Codable, Sendable {
    public let imagePath: String
    public let alreadyLoaded: Bool
    public let objectsLoaded: Bool
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

public struct MCPIsImageLoadedResponse: Codable, Sendable {
    public let imagePath: String
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

public struct MCPLoadObjectsResponse: Codable, Sendable {
    public let imagePath: String
    public let alreadyLoaded: Bool
    public let objectCount: Int
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

public struct MCPIsObjectsLoadedResponse: Codable, Sendable {
    public let imagePath: String
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

public struct MCPMemberAddressInfo: Codable, Sendable {
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

    public init(from member: RuntimeMemberAddress) {
        self.name = member.name
        self.kind = member.kind
        self.symbolName = member.symbolName
        self.address = member.address
    }
}

public struct MCPMemberAddressesResponse: Codable, Sendable {
    public let typeName: String?
    public let members: [MCPMemberAddressInfo]
    public let error: String?

    public init(typeName: String?, members: [MCPMemberAddressInfo], error: String?) {
        self.typeName = typeName
        self.members = members
        self.error = error
    }
}
