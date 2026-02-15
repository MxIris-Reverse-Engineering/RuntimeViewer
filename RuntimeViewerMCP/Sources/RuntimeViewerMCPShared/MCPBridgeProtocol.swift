import Foundation

// MARK: - Command identifiers

public enum MCPBridgeCommand: String, Sendable {
    case listWindows = "com.RuntimeViewer.MCP.listWindows"
    case selectedType = "com.RuntimeViewer.MCP.selectedType"
    case typeInterface = "com.RuntimeViewer.MCP.typeInterface"
    case listTypes = "com.RuntimeViewer.MCP.listTypes"
    case searchTypes = "com.RuntimeViewer.MCP.searchTypes"
    case grepTypeInterface = "com.RuntimeViewer.MCP.grepTypeInterface"
}

// MARK: - List Windows

public struct MCPWindowInfo: Codable, Sendable {
    public let identifier: String
    public let displayName: String?
    public let isKeyWindow: Bool
    public let selectedTypeName: String?
    public let selectedTypeImagePath: String?

    public init(
        identifier: String,
        displayName: String?,
        isKeyWindow: Bool,
        selectedTypeName: String?,
        selectedTypeImagePath: String?
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.isKeyWindow = isKeyWindow
        self.selectedTypeName = selectedTypeName
        self.selectedTypeImagePath = selectedTypeImagePath
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
    public let typeName: String?
    public let displayName: String?
    public let typeKind: String?
    public let interfaceText: String?

    public init(
        imagePath: String?,
        typeName: String?,
        displayName: String?,
        typeKind: String?,
        interfaceText: String?
    ) {
        self.imagePath = imagePath
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
    public let typeName: String

    public init(windowIdentifier: String, imagePath: String?, typeName: String) {
        self.windowIdentifier = windowIdentifier
        self.imagePath = imagePath
        self.typeName = typeName
    }
}

public struct MCPTypeInterfaceResponse: Codable, Sendable {
    public let imagePath: String?
    public let typeName: String?
    public let displayName: String?
    public let typeKind: String?
    public let interfaceText: String?
    public let error: String?

    public init(
        imagePath: String?,
        typeName: String?,
        displayName: String?,
        typeKind: String?,
        interfaceText: String?,
        error: String?
    ) {
        self.imagePath = imagePath
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

    public init(name: String, displayName: String, kind: String, imagePath: String) {
        self.name = name
        self.displayName = displayName
        self.kind = kind
        self.imagePath = imagePath
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

    public init(windowIdentifier: String, imagePath: String?) {
        self.windowIdentifier = windowIdentifier
        self.imagePath = imagePath
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

    public init(windowIdentifier: String, query: String, imagePath: String?) {
        self.windowIdentifier = windowIdentifier
        self.query = query
        self.imagePath = imagePath
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
    public let pattern: String

    public init(windowIdentifier: String, imagePath: String?, pattern: String) {
        self.windowIdentifier = windowIdentifier
        self.imagePath = imagePath
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
