#if os(macOS)
import RuntimeViewerApplication
import RuntimeViewerMCPShared

/// A context representing a single window for MCP bridge operations.
public struct MCPBridgeWindowContext {
    public let identifier: String
    public let displayName: String?
    public let isKeyWindow: Bool
    public let appState: AppState

    public init(
        identifier: String,
        displayName: String?,
        isKeyWindow: Bool,
        appState: AppState
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.isKeyWindow = isKeyWindow
        self.appState = appState
    }
}

/// Protocol for providing window information to the MCP bridge.
/// The main app should implement this to map its document/window architecture to MCP.
public protocol MCPBridgeWindowProvider: AnyObject, Sendable {
    @MainActor func allWindowContexts() -> [MCPBridgeWindowContext]
    @MainActor func windowContext(forIdentifier identifier: String) -> MCPBridgeWindowContext?
}
#endif
