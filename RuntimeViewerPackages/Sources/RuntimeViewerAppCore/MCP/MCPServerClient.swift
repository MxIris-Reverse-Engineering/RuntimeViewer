#if os(macOS)

import Dependencies

/// Starts and stops the app's MCP server and says where it stands, for the toolbar's MCP status
/// popover.
///
/// A dependency because the server lives in `RuntimeViewerMCPBridge`, which depends on this
/// module, so this module cannot name it. The live value is the bridge's `MCPService`; the bridge
/// adds the `DependencyKey` conformance, and the key is `public` rather than `package` for that
/// reason: the bridge is another package. Reading `state` inside `Observable.tracking` follows the
/// server, whose state is observable.
public struct MCPServerClient: Sendable {
    /// Where the server stands now.
    public var state: @MainActor @Sendable () -> MCPServerState

    /// Starts the server again for the documents it was last started for. The app starts it at
    /// launch, so there is always something to start it for.
    public var start: @MainActor @Sendable () -> Void

    /// Stops the server and removes its port file.
    public var stop: @MainActor @Sendable () -> Void

    public init(
        state: @escaping @MainActor @Sendable () -> MCPServerState,
        start: @escaping @MainActor @Sendable () -> Void,
        stop: @escaping @MainActor @Sendable () -> Void
    ) {
        self.state = state
        self.start = start
        self.stop = stop
    }
}

extension MCPServerClient {
    /// A server that is stopped and stays stopped.
    public static let inert = MCPServerClient(state: { .stopped }, start: {}, stop: {})
}

/// The MCP server the status popover drives. `RuntimeViewerMCPBridge` gives it its live value; a
/// test gets `MCPServerClient.inert` unless it overrides it.
public enum MCPServerClientKey: TestDependencyKey {
    public static let testValue = MCPServerClient.inert
}

extension DependencyValues {
    public var mcpServerClient: MCPServerClient {
        get { self[MCPServerClientKey.self] }
        set { self[MCPServerClientKey.self] = newValue }
    }
}

#endif
