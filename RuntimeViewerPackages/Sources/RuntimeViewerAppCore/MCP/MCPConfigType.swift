#if os(macOS)

import RuntimeViewerSettings

/// A way of adding the app's MCP server to a client, as the status popover offers to copy it.
public enum MCPConfigType {
    case claudeCode
    case codex
    case json

    public func configString(port: UInt16) -> String {
        let serverName = Settings.MCP.serverName
        let url = Settings.MCP.serverURL(port: port)
        switch self {
        case .claudeCode:
            return "claude mcp add \(serverName) --transport http \(url)"
        case .codex:
            return "codex mcp add \(serverName) --url \(url)"
        case .json:
            return Settings.MCP.clientConfigurationJSON(port: port)
        }
    }
}

#endif
