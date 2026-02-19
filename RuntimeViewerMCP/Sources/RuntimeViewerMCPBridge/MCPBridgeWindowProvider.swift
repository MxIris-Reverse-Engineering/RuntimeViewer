#if os(macOS)
import RuntimeViewerCore
import RuntimeViewerMCPShared

/// A context representing a single window for MCP bridge operations.
public struct MCPBridgeWindowContext {
    public let identifier: String
    public let displayName: String?
    public let isKeyWindow: Bool
    public let selectedRuntimeObject: RuntimeObject?
    public let runtimeEngine: RuntimeEngine

    public init(
        identifier: String,
        displayName: String?,
        isKeyWindow: Bool,
        selectedRuntimeObject: RuntimeObject?,
        runtimeEngine: RuntimeEngine
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.isKeyWindow = isKeyWindow
        self.selectedRuntimeObject = selectedRuntimeObject
        self.runtimeEngine = runtimeEngine
    }
}

/// Protocol for providing window information to the MCP bridge.
/// The main app should implement this to map its document/window architecture to MCP.
public protocol MCPBridgeWindowProvider: AnyObject, Sendable {
    @MainActor func allWindowContexts() -> [MCPBridgeWindowContext]
    @MainActor func windowContext(forIdentifier identifier: String) -> MCPBridgeWindowContext?
}
#endif
