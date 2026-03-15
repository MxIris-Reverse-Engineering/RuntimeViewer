import Foundation
import RuntimeViewerCore
import MemberwiseInit

public enum MCPBridgeDocumentProviderError: LocalizedError {
    case documentNotFound(identifier: String)

    public var errorDescription: String? {
        switch self {
        case .documentNotFound(let identifier):
            "Document not found for identifier: \(identifier)"
        }
    }
}

/// A context representing a single document for MCP bridge operations.
@MemberwiseInit(.public)
public struct MCPBridgeDocumentContext {
    public let identifier: String
    public let displayName: String?
    public let isKeyWindow: Bool
    public let selectedRuntimeObject: RuntimeObject?
    public let selectedImageNode: RuntimeImageNode?
    public let runtimeEngine: RuntimeEngine
}

/// Protocol for providing document information to the MCP bridge.
/// The main app should implement this to map its document architecture to MCP.
public protocol MCPBridgeDocumentProvider: AnyObject, Sendable {
    func allDocumentContexts() async -> [MCPBridgeDocumentContext]
    func documentContext(forIdentifier identifier: String) async throws -> MCPBridgeDocumentContext
}
