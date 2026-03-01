#if os(macOS)
import RuntimeViewerCore
import RuntimeViewerMCPShared
import MemberwiseInit

/// A context representing a single window for MCP bridge operations.
@MemberwiseInit(.public)
public struct MCPBridgeWindowContext {
    public let identifier: String
    public let displayName: String?
    public let isKeyWindow: Bool
    public let selectedRuntimeObject: RuntimeObject?
    public let selectedImageNode: RuntimeImageNode?
    public let runtimeEngine: RuntimeEngine
}

/// Protocol for providing window information to the MCP bridge.
/// The main app should implement this to map its document/window architecture to MCP.
public protocol MCPBridgeWindowProvider: AnyObject, Sendable {
    func allWindowContexts() async -> [MCPBridgeWindowContext]
    func windowContext(forIdentifier identifier: String) async -> MCPBridgeWindowContext?
}
#endif
