# MCP Multi-Client Support Design

## Summary

Replace the current single-client stdio-based MCP architecture with an in-app Streamable HTTP server that supports multiple concurrent LLM client connections.

## Current Architecture

```
LLM Client → (stdio) → RuntimeViewerMCPServer (separate process) → (TCP bridge) → MCPBridgeServer (in-app)
```

- Single client only (stdio transport)
- Three-layer indirection: MCP Server → Bridge TCP → App
- Bridge uses length-prefixed JSON frames over TCP

## New Architecture

```
LLM Client A ── HTTP ──┐
LLM Client B ── HTTP ──┼──▶ Hummingbird HTTP Server (in-app, port N)
LLM Client C ── HTTP ──┘         │
                          MCPSessionManager
                         ┌───────┼───────┐
                    Session A  Session B  Session C
                   (Server +  (Server +  (Server +
                   Transport) Transport) Transport)
                         └───────┼───────┘
                          MCPBridgeServer (actor, shared)
                                 │
                         MCPBridgeWindowProvider
                                 │
                          DocumentState / RuntimeEngine
```

- Multiple clients via Streamable HTTP (MCP spec 2025-03-26+)
- Single process: everything runs inside RuntimeViewerApp
- Each client gets its own MCP session (Server + StatefulHTTPServerTransport)
- All sessions share one MCPBridgeServer actor for business logic

## Key Components

### MCPHTTPServer (new)

Embeds a Hummingbird HTTP server inside the app. Listens on a dynamic port (or user-configured fixed port). Routes POST/GET/DELETE to the session manager. Writes port to `~/Library/Application Support/RuntimeViewer/mcp-http-port` on startup, removes on shutdown.

### MCPSessionManager (new)

Manages multiple client sessions. Creates a new `(Server, StatefulHTTPServerTransport)` pair when a client sends an `initialize` request without a session ID. Routes subsequent requests by `Mcp-Session-Id` header. Destroys sessions on DELETE.

### MCPToolRegistry (new)

Centralizes tool definitions (list_windows, get_selected_type, get_type_interface, list_types, search_types, get_member_addresses) and handler registration. Each new session registers the same tools, all delegating to the shared MCPBridgeServer.

### MCPBridgeServer (refactored)

Retains all existing business logic (handleListWindows, handleTypeInterface, etc.). Removes MCPBridgeListener dependency. Makes handle methods public for direct invocation from tool handlers. Already an actor — concurrent-safe by design.

## Request Lifecycle

1. **Initialize**: Client POST /mcp (no session ID) → SessionManager creates new session → transport returns SSE stream + Mcp-Session-Id
2. **Tool call**: Client POST /mcp (with session ID) → SessionManager routes to session → transport dispatches to Server → tool handler calls MCPBridgeServer → response
3. **Disconnect**: Client DELETE /mcp (with session ID) → session destroyed and removed

## Code to Remove

| File | Reason |
|------|--------|
| `MCPBridgeListener.swift` | TCP listener replaced by Hummingbird |
| `MCPBridgeTransport.swift` (MCPShared) | Frame encoding/decoding no longer needed |
| `RuntimeViewerMCPServer/main.swift` | Separate MCP process eliminated |
| `RuntimeViewerMCPServer/MCPBridgeClient.swift` | Bridge client no longer needed |
| `RuntimeViewerMCPServer/MCPBridgeConnection.swift` | Bridge connection no longer needed |

## Package Changes

`RuntimeViewerMCP/Package.swift`:
- Add dependency: `hummingbird`
- Add dependency: `swift-sdk` (MCP SDK, moved from Xcode project-level)
- Remove target: `RuntimeViewerMCPShared` (bridge protocol no longer needed)
- Keep `RuntimeViewerMCPBridge` target (rename optional)

## Client Configuration

LLM clients configure HTTP URL instead of stdio command:

```json
{
  "mcpServers": {
    "runtime-viewer": {
      "url": "http://127.0.0.1:<port>/mcp"
    }
  }
}
```

## App Integration

`AppDelegate` changes from `startMCPBridgeServer()` to `startMCPHTTPServer()`. Creates MCPBridgeServer with WindowProvider, wraps it in MCPHTTPServer, starts Hummingbird. Stops on `applicationWillTerminate`.
