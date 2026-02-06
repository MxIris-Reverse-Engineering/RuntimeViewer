import Foundation

// MARK: - Command identifiers

public enum MCPBridgeCommand: String, Sendable {
    case getSelectedType = "com.RuntimeViewer.MCP.getSelectedType"
    case getTypeInterface = "com.RuntimeViewer.MCP.getTypeInterface"
}

// MARK: - Get Selected Type

public struct MCPGetSelectedTypeResponse: Codable, Sendable {
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

// MARK: - Get Type Interface

public struct MCPGetTypeInterfaceRequest: Codable, Sendable {
    public let imagePath: String
    public let typeName: String

    public init(imagePath: String, typeName: String) {
        self.imagePath = imagePath
        self.typeName = typeName
    }
}

public struct MCPGetTypeInterfaceResponse: Codable, Sendable {
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
