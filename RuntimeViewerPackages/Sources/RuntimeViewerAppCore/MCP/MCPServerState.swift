#if os(macOS)

/// Where the app's MCP server stands: turned off in Settings, on but not listening, or listening on
/// a port.
public enum MCPServerState: Equatable, Sendable {
    case disabled
    case stopped
    case running(port: UInt16)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var port: UInt16? {
        if case .running(let port) = self { return port }
        return nil
    }
}

#endif
