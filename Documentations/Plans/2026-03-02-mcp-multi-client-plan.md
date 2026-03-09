# MCP Multi-Client Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the stdio-based single-client MCP architecture with an in-app Streamable HTTP server supporting multiple concurrent LLM client connections.

**Architecture:** Embed a Hummingbird HTTP server inside RuntimeViewerApp. Each LLM client gets its own MCP session (`Server` + `StatefulHTTPServerTransport`). All sessions share one `MCPBridgeServer` actor for business logic. Eliminates the separate MCP server process and TCP bridge layer entirely.

**Tech Stack:** Swift MCP SDK (`StatefulHTTPServerTransport`), Hummingbird 2.x (HTTP server), Network.framework (removed)

**Design doc:** `docs/plans/2026-03-02-mcp-multi-client-design.md`

**Reference implementation:** MCP SDK's `Sources/MCPConformance/Server/HTTPApp.swift` — multi-session HTTP server pattern we're adapting.

---

## Task 1: Update Package.swift — Add Dependencies

**Files:**
- Modify: `RuntimeViewerMCP/Package.swift`

**Step 1: Add MCP SDK and Hummingbird dependencies, restructure targets**

```swift
// RuntimeViewerMCP/Package.swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RuntimeViewerMCP",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "RuntimeViewerMCPBridge",
            targets: ["RuntimeViewerMCPBridge"]
        ),
    ],
    dependencies: [
        .package(path: "../RuntimeViewerCore"),
        .package(path: "../RuntimeViewerPackages"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "RuntimeViewerMCPBridge",
            dependencies: [
                .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
                .product(name: "RuntimeViewerApplication", package: "RuntimeViewerPackages"),
                .product(name: "RuntimeViewerSettings", package: "RuntimeViewerPackages"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
```

Key changes:
- Remove `RuntimeViewerMCPShared` product and target (will merge data types into MCPBridge)
- Remove `RuntimeViewerMCPShared` from MCPBridge dependencies
- Add `MCP` (swift-sdk) and `Hummingbird` dependencies
- Keep only `RuntimeViewerMCPBridge` product

**Step 2: Move data model types from MCPShared into MCPBridge**

Move `RuntimeViewerMCPShared/MCPBridgeProtocol.swift` to `RuntimeViewerMCPBridge/MCPBridgeProtocol.swift`.

Remove from the file:
- `MCPBridgeCommand` enum (no longer needed — was only used for TCP bridge routing)

Keep all request/response structs as-is (still used by MCPBridgeServer):
- `MCPWindowInfo`, `MCPListWindowsResponse`
- `MCPSelectedTypeRequest`, `MCPSelectedTypeResponse`
- `MCPTypeInterfaceRequest`, `MCPTypeInterfaceResponse`
- `MCPRuntimeTypeInfo`, `MCPGrepMatch`
- `MCPListTypesRequest`, `MCPListTypesResponse`
- `MCPSearchTypesRequest`, `MCPSearchTypesResponse`
- `MCPGrepTypeInterfaceRequest`, `MCPGrepTypeInterfaceResponse`
- `MCPMemberAddressesRequest`, `MCPMemberAddressInfo`, `MCPMemberAddressesResponse`

**Step 3: Delete obsolete MCPShared files**

Delete:
- `RuntimeViewerMCP/Sources/RuntimeViewerMCPShared/` (entire directory)
  - `MCPBridgeProtocol.swift` (moved to MCPBridge)
  - `MCPBridgeTransport.swift` (frame encoding — no longer needed)

**Step 4: Update MCPBridgeServer imports**

In `MCPBridgeServer.swift`, remove `import RuntimeViewerMCPShared` (types are now in the same module).

**Step 5: Build to verify**

```bash
cd RuntimeViewerMCP && swift build 2>&1 | xcsift
```

Expected: Build succeeds with MCP SDK and Hummingbird resolved.

**Step 6: Commit**

```bash
git add RuntimeViewerMCP/
git commit -m "refactor(mcp): add MCP SDK + Hummingbird deps, merge MCPShared into MCPBridge"
```

---

## Task 2: Refactor MCPBridgeServer — Remove Listener, Expose Handles

**Files:**
- Modify: `RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/MCPBridgeServer.swift`
- Delete: `RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/MCPBridgeListener.swift`

**Step 1: Delete MCPBridgeListener.swift**

This file is entirely replaced by the Hummingbird HTTP server.

**Step 2: Refactor MCPBridgeServer**

Remove:
- `MCPBridgeListener` property
- `init(windowProvider:port:)` — replace with `init(windowProvider:)`
- `start()` method (listener startup)
- `stop()` method (listener shutdown)
- `deinit` (was calling stop)
- `processRequest(_:)` method (TCP envelope dispatch — replaced by direct calls)

Make public:
- All `handleXXX` methods (previously `private`)

```swift
import Foundation
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerSettings
import Dependencies
import OSLog

private let logger = Logger(subsystem: "com.RuntimeViewer.MCPBridge", category: "Server")

public actor MCPBridgeServer {
    private let windowProvider: MCPBridgeWindowProvider

    @Dependency(\.appDefaults)
    private var appDefaults

    public init(windowProvider: MCPBridgeWindowProvider) {
        self.windowProvider = windowProvider
    }

    // MARK: - Public Handle Methods

    public func handleListWindows() async -> MCPListWindowsResponse {
        // ... (existing logic, unchanged)
    }

    public func handleSelectedType(_ request: MCPSelectedTypeRequest) async -> MCPSelectedTypeResponse {
        // ... (existing logic, unchanged)
    }

    public func handleTypeInterface(_ request: MCPTypeInterfaceRequest) async -> MCPTypeInterfaceResponse {
        // ... (existing logic, unchanged)
    }

    public func handleListTypes(_ request: MCPListTypesRequest) async -> MCPListTypesResponse {
        // ... (existing logic, unchanged)
    }

    public func handleSearchTypes(_ request: MCPSearchTypesRequest) async -> MCPSearchTypesResponse {
        // ... (existing logic, unchanged)
    }

    public func handleGrepTypeInterface(_ request: MCPGrepTypeInterfaceRequest) async -> MCPGrepTypeInterfaceResponse {
        // ... (existing logic, unchanged)
    }

    public func handleMemberAddresses(_ request: MCPMemberAddressesRequest) async -> MCPMemberAddressesResponse {
        // ... (existing logic, unchanged)
    }

    // MARK: - Private Helpers (all unchanged)

    private func runtimeEngine(forWindowIdentifier identifier: String) async -> RuntimeEngine { ... }
    private func generationOptions() -> RuntimeObjectInterface.GenerationOptions { ... }
    private func flattenObjects(_ objects: [RuntimeObject]) -> [RuntimeObject] { ... }
    private func findObject(named name: String, in objects: [RuntimeObject]) -> RuntimeObject? { ... }
}
```

**Step 3: Build to verify**

```bash
cd RuntimeViewerMCP && swift build 2>&1 | xcsift
```

**Step 4: Commit**

```bash
git add RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/
git commit -m "refactor(mcp): remove MCPBridgeListener, expose MCPBridgeServer handle methods"
```

---

## Task 3: Create MCPToolRegistry — Tool Definitions + Handler Registration

**Files:**
- Create: `RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/MCPToolRegistry.swift`

**Context:** This file ports tool definitions from `RuntimeViewerUsingAppKit/RuntimeViewerMCPServer/main.swift` and the response formatting logic. Each new MCP session calls `registerTools(on:)` to wire up tool handlers that delegate to the shared `MCPBridgeServer`.

**Step 1: Create MCPToolRegistry.swift**

```swift
import Foundation
import MCP
import OSLog

private let logger = Logger(subsystem: "com.RuntimeViewer.MCPBridge", category: "ToolRegistry")

public struct MCPToolRegistry: Sendable {
    private let bridgeServer: MCPBridgeServer

    public init(bridgeServer: MCPBridgeServer) {
        self.bridgeServer = bridgeServer
    }

    // MARK: - Tool Definitions

    static let tools: [Tool] = [
        Tool(
            name: "list_windows",
            description: """
                Lists all open RuntimeViewer document windows. Call this first — every other tool requires a window_identifier returned here. \
                Each entry contains: identifier (stable per window session), display title, key-window flag, \
                and the currently selected type's name and image path (if any). \
                Returns an empty list when no documents are open; in that case, ask the user to launch RuntimeViewer and open a document.
                """,
            inputSchema: .object([
                "type": .string("object"),
            ])
        ),
        Tool(
            name: "get_selected_type",
            description: """
                Returns the type currently selected in the sidebar of a RuntimeViewer window. \
                Response includes: name (internal/mangled for Swift), display name (human-readable), \
                kind (e.g. "Objective-C Class", "Swift Struct", "Swift Protocol", etc.), \
                image path (the framework or dylib it belongs to), and the full generated interface text. \
                For ObjC types the interface is an @interface header; for Swift types it is a Swift-style declaration \
                including methods, properties, protocol conformances, and all extensions/conformance extensions. \
                Returns a "no type selected" message if the sidebar has no selection.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "window_identifier": .object([
                        "type": .string("string"),
                        "description": .string("The window identifier obtained from list_windows"),
                    ]),
                ]),
                "required": .array([.string("window_identifier")]),
            ])
        ),
        Tool(
            name: "get_type_interface",
            description: """
                Retrieves the full generated interface declaration for a type by exact name match. \
                Matches against both the internal name and display name of each type. \
                For ObjC types the output is an @interface header with methods, properties, and protocol conformances. \
                For Swift types it is a Swift declaration followed by all extension and conformance extension blocks. \
                Providing image_path restricts the search to a single image and is significantly faster; \
                omitting it searches all previously loaded images. \
                Use search_types first if you are unsure of the exact type name or image path.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "window_identifier": .object([
                        "type": .string("string"),
                        "description": .string("The window identifier obtained from list_windows"),
                    ]),
                    "image_path": .object([
                        "type": .string("string"),
                        "description": .string("Full path of the image (framework/dylib) containing the type. Strongly recommended for faster lookup. If omitted, searches all loaded images."),
                    ]),
                    "type_name": .object([
                        "type": .string("string"),
                        "description": .string("Exact type name — matches against both internal name (e.g. mangled Swift name) and display name (e.g. 'NSView', 'SwiftUI.Text')"),
                    ]),
                ]),
                "required": .array([.string("window_identifier"), .string("type_name")]),
            ])
        ),
        Tool(
            name: "list_types",
            description: """
                Lists all runtime types in an image, grouped by kind with a total count. \
                WARNING: omitting image_path enumerates every type across all loaded images — \
                this can produce an extremely large response and trigger heavy I/O. Always provide image_path when possible. \
                If you only need to find types by name, prefer search_types instead.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "window_identifier": .object([
                        "type": .string("string"),
                        "description": .string("The window identifier obtained from list_windows"),
                    ]),
                    "image_path": .object([
                        "type": .string("string"),
                        "description": .string("Full path of the image (framework/dylib) to list types from. Strongly recommended — omitting it dumps ALL loaded images which can be extremely large."),
                    ]),
                ]),
                "required": .array([.string("window_identifier")]),
            ])
        ),
        Tool(
            name: "search_types",
            description: """
                Searches for runtime types by name using case-insensitive substring matching against both \
                the internal name (mangled for Swift) and the display name (human-readable). \
                Returns each match with its display name, kind, and full image path. \
                This is the preferred way to locate a type when you do not know its exact name or image path.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "window_identifier": .object([
                        "type": .string("string"),
                        "description": .string("The window identifier obtained from list_windows"),
                    ]),
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Case-insensitive substring to match against type names (e.g. 'ViewController', 'NSWindow', 'Text')"),
                    ]),
                    "image_path": .object([
                        "type": .string("string"),
                        "description": .string("Restrict search to a specific image path. If omitted, searches all loaded images."),
                    ]),
                ]),
                "required": .array([.string("window_identifier"), .string("query")]),
            ])
        ),
        Tool(
            name: "get_member_addresses",
            description: """
                Returns runtime memory addresses of a type's members. Supports both Swift and Objective-C types (not C structs/unions). \
                Each entry includes: kind, demangled/readable name, symbol name, and hex address. \
                Useful for setting breakpoints, hooking functions, or correlating disassembly with source symbols.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "window_identifier": .object([
                        "type": .string("string"),
                        "description": .string("The window identifier obtained from list_windows"),
                    ]),
                    "image_path": .object([
                        "type": .string("string"),
                        "description": .string("Full path of the image (framework/dylib) containing the type. Recommended for faster lookup. If omitted, searches all loaded images."),
                    ]),
                    "type_name": .object([
                        "type": .string("string"),
                        "description": .string("The name of the type to inspect — works for both Swift and ObjC types"),
                    ]),
                    "member_name": .object([
                        "type": .string("string"),
                        "description": .string("Filter to members whose name contains this string (case-insensitive). If omitted, returns all members."),
                    ]),
                ]),
                "required": .array([.string("window_identifier"), .string("type_name")]),
            ])
        ),
    ]

    // MARK: - Server Registration

    /// Registers all MCP tools on the given Server instance, delegating to the shared MCPBridgeServer.
    public func registerTools(on server: Server) async {
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.tools)
        }

        let bridgeServer = self.bridgeServer

        await server.withMethodHandler(CallTool.self) { params in
            do {
                return try await Self.handleToolCall(params, bridgeServer: bridgeServer)
            } catch {
                logger.error("Tool call failed: \(error)")
                return .init(
                    content: [.text("Error: \(error.localizedDescription)")],
                    isError: true
                )
            }
        }
    }

    // MARK: - Tool Call Dispatch

    private static func handleToolCall(
        _ params: CallTool.Parameters,
        bridgeServer: MCPBridgeServer
    ) async throws -> CallTool.Result {
        switch params.name {
        case "list_windows":
            return try await handleListWindows(bridgeServer: bridgeServer)

        case "get_selected_type":
            let windowIdentifier = try requireParam(params, "window_identifier")
            return try await handleSelectedType(windowIdentifier: windowIdentifier, bridgeServer: bridgeServer)

        case "get_type_interface":
            let windowIdentifier = try requireParam(params, "window_identifier")
            let typeName = try requireParam(params, "type_name")
            let imagePath = params.arguments?["image_path"]?.stringValue
            return try await handleTypeInterface(windowIdentifier: windowIdentifier, imagePath: imagePath, typeName: typeName, bridgeServer: bridgeServer)

        case "list_types":
            let windowIdentifier = try requireParam(params, "window_identifier")
            let imagePath = params.arguments?["image_path"]?.stringValue
            return try await handleListTypes(windowIdentifier: windowIdentifier, imagePath: imagePath, bridgeServer: bridgeServer)

        case "search_types":
            let windowIdentifier = try requireParam(params, "window_identifier")
            let query = try requireParam(params, "query")
            let imagePath = params.arguments?["image_path"]?.stringValue
            return try await handleSearchTypes(windowIdentifier: windowIdentifier, query: query, imagePath: imagePath, bridgeServer: bridgeServer)

        case "get_member_addresses":
            let windowIdentifier = try requireParam(params, "window_identifier")
            let typeName = try requireParam(params, "type_name")
            let imagePath = params.arguments?["image_path"]?.stringValue
            let memberName = params.arguments?["member_name"]?.stringValue
            return try await handleMemberAddresses(windowIdentifier: windowIdentifier, imagePath: imagePath, typeName: typeName, memberName: memberName, bridgeServer: bridgeServer)

        default:
            throw MCPError.invalidParams("Unknown tool: \(params.name)")
        }
    }

    // MARK: - Parameter Helpers

    private static func requireParam(_ params: CallTool.Parameters, _ name: String) throws -> String {
        guard let value = params.arguments?[name]?.stringValue else {
            throw MCPError.invalidParams("'\(name)' parameter is required.")
        }
        return value
    }

    // MARK: - Response Formatters
    // (Port each case from RuntimeViewerMCPServer/main.swift, replacing client.xxx() with bridgeServer.handleXxx())

    private static func handleListWindows(bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = await bridgeServer.handleListWindows()
        if response.windows.isEmpty {
            return .init(content: [.text("No RuntimeViewer windows are currently open.")], isError: false)
        }
        var text = "Open Windows:\n"
        for window in response.windows {
            text += "\n  Identifier: \(window.identifier)"
            if let displayName = window.displayName {
                text += "\n  Title: \(displayName)"
            }
            text += "\n  Key Window: \(window.isKeyWindow)"
            if let selectedType = window.selectedTypeName {
                text += "\n  Selected Type: \(selectedType)"
            }
            if let imagePath = window.selectedTypeImagePath {
                text += "\n  Selected Type Image: \(imagePath)"
            }
            text += "\n"
        }
        return .init(content: [.text(text)], isError: false)
    }

    private static func handleSelectedType(windowIdentifier: String, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = await bridgeServer.handleSelectedType(MCPSelectedTypeRequest(windowIdentifier: windowIdentifier))
        guard let typeName = response.typeName else {
            return .init(content: [.text("No type is currently selected in the specified window.")], isError: false)
        }
        var text = "Selected Type:\n"
        text += "  Name: \(response.displayName ?? typeName)\n"
        if let kind = response.typeKind { text += "  Kind: \(kind)\n" }
        if let imagePath = response.imagePath { text += "  Image: \(imagePath)\n" }
        if let interfaceText = response.interfaceText { text += "\nInterface:\n\(interfaceText)" }
        return .init(content: [.text(text)], isError: false)
    }

    private static func handleTypeInterface(windowIdentifier: String, imagePath: String?, typeName: String, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = await bridgeServer.handleTypeInterface(MCPTypeInterfaceRequest(windowIdentifier: windowIdentifier, imagePath: imagePath, typeName: typeName))
        if let error = response.error {
            return .init(content: [.text("Error: \(error)")], isError: true)
        }
        var text = "Type: \(response.displayName ?? typeName)\n"
        if let kind = response.typeKind { text += "Kind: \(kind)\n" }
        if let responseImagePath = response.imagePath { text += "Image: \(responseImagePath)\n" }
        if let interfaceText = response.interfaceText {
            text += "\nInterface:\n\(interfaceText)"
        } else {
            text += "\nNo interface text available."
        }
        return .init(content: [.text(text)], isError: false)
    }

    private static func handleListTypes(windowIdentifier: String, imagePath: String?, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = await bridgeServer.handleListTypes(MCPListTypesRequest(windowIdentifier: windowIdentifier, imagePath: imagePath))
        if let error = response.error {
            return .init(content: [.text("Error: \(error)")], isError: true)
        }
        if response.types.isEmpty {
            let scope = imagePath.map { "image '\($0)'" } ?? "all loaded images"
            return .init(content: [.text("No types found in \(scope).")], isError: false)
        }
        var grouped: [String: [MCPRuntimeTypeInfo]] = [:]
        for type in response.types { grouped[type.kind, default: []].append(type) }
        let scopeName: String
        if let imagePath { scopeName = String(imagePath.split(separator: "/").last ?? Substring(imagePath)) }
        else { scopeName = "all loaded images" }
        var text = "Types in \(scopeName):\nTotal: \(response.types.count) types\n"
        for (kind, types) in grouped.sorted(by: { $0.key < $1.key }) {
            text += "\n[\(kind)] (\(types.count)):\n"
            for type in types { text += "  - \(type.displayName)\n" }
        }
        return .init(content: [.text(text)], isError: false)
    }

    private static func handleSearchTypes(windowIdentifier: String, query: String, imagePath: String?, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = await bridgeServer.handleSearchTypes(MCPSearchTypesRequest(windowIdentifier: windowIdentifier, query: query, imagePath: imagePath))
        if let error = response.error {
            return .init(content: [.text("Error: \(error)")], isError: true)
        }
        if response.types.isEmpty {
            var text = "No types matching '\(query)'"
            if let imagePath { text += " in image '\(imagePath)'" }
            return .init(content: [.text(text + ".")], isError: false)
        }
        var text = "Search results for '\(query)':\nFound \(response.types.count) matching types\n\n"
        for type in response.types {
            let imageName = type.imagePath.split(separator: "/").last ?? Substring(type.imagePath)
            text += "  \(type.displayName) [\(type.kind)] — \(imageName)\n"
        }
        return .init(content: [.text(text)], isError: false)
    }

    private static func handleMemberAddresses(windowIdentifier: String, imagePath: String?, typeName: String, memberName: String?, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = await bridgeServer.handleMemberAddresses(MCPMemberAddressesRequest(windowIdentifier: windowIdentifier, imagePath: imagePath, typeName: typeName, memberName: memberName))
        if let error = response.error {
            return .init(content: [.text("Error: \(error)")], isError: true)
        }
        if response.members.isEmpty {
            let filterNote = memberName.map { " matching '\($0)'" } ?? ""
            return .init(content: [.text("No member addresses found\(filterNote) for '\(typeName)'.")], isError: false)
        }
        var text = "Member addresses for \(response.typeName ?? typeName):\n"
        if let memberName { text += "Filter: '\(memberName)'\n" }
        text += "Found \(response.members.count) member(s)\n\n"
        for member in response.members {
            text += "  [\(member.kind)] \(member.name)\n"
            text += "    Address:    \(member.address)\n"
            text += "    Symbol:     \(member.symbolName)\n"
        }
        return .init(content: [.text(text)], isError: false)
    }
}
```

**Step 2: Build to verify**

```bash
cd RuntimeViewerMCP && swift build 2>&1 | xcsift
```

**Step 3: Commit**

```bash
git add RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/MCPToolRegistry.swift
git commit -m "feat(mcp): add MCPToolRegistry with tool definitions and handler registration"
```

---

## Task 4: Create MCPHTTPServer — Hummingbird + Session Management

**Files:**
- Create: `RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/MCPHTTPServer.swift`

**Context:** This is the main new component. It embeds a Hummingbird HTTP server, manages per-client MCP sessions, and routes HTTP requests to the correct `StatefulHTTPServerTransport`. The session management pattern is adapted from MCP SDK's `HTTPApp.swift` reference implementation.

**Step 1: Create MCPHTTPServer.swift**

```swift
import Foundation
import Hummingbird
import MCP
import NIOCore
import OSLog

private let logger = Logger(subsystem: "com.RuntimeViewer.MCPBridge", category: "HTTPServer")

public actor MCPHTTPServer {
    private let bridgeServer: MCPBridgeServer
    private let toolRegistry: MCPToolRegistry
    private var serverTask: Task<Void, any Error>?
    private var sessions: [String: SessionContext] = [:]
    private var port: UInt16 = 0

    private struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    private let portFilePath: String

    public init(bridgeServer: MCPBridgeServer) throws {
        self.bridgeServer = bridgeServer
        self.toolRegistry = MCPToolRegistry(bridgeServer: bridgeServer)
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let runtimeViewerDir = appSupportURL.appendingPathComponent("RuntimeViewer")
        try FileManager.default.createDirectory(at: runtimeViewerDir, withIntermediateDirectories: true)
        self.portFilePath = runtimeViewerDir.appendingPathComponent("mcp-http-port").path
    }

    // MARK: - Lifecycle

    public func start() async throws {
        // Build router with all MCP routes
        let router = Router()

        // Store self reference for route handlers
        let httpServer = self

        router.post("/mcp") { request, context -> Response in
            try await httpServer.handleMCPRoute(request, context: context)
        }

        router.get("/mcp") { request, context -> Response in
            try await httpServer.handleMCPRoute(request, context: context)
        }

        router.delete("/mcp") { request, context -> Response in
            try await httpServer.handleMCPRoute(request, context: context)
        }

        // Use a continuation to get the actual port after binding
        let resolvedPort = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let app = Application(
                router: router,
                configuration: .init(address: .hostname("127.0.0.1", port: 0)),
                onServerRunning: { channel in
                    let port = channel.localAddress?.port ?? 0
                    continuation.resume(returning: port)
                }
            )

            self.serverTask = Task.detached {
                try await app.runService()
            }
        }

        self.port = UInt16(resolvedPort)
        writePortFile(port: self.port)
        logger.info("MCP HTTP server listening on port \(self.port)")

        // Start session cleanup loop
        Task { await sessionCleanupLoop() }
    }

    public nonisolated func stop() {
        Task { await performStop() }
    }

    private func performStop() {
        serverTask?.cancel()
        serverTask = nil
        removePortFile()
        logger.info("MCP HTTP server stopped")
    }

    // MARK: - HTTP Route Handler

    private func handleMCPRoute(_ request: Request, context: some RequestContext) async throws -> Response {
        // Convert Hummingbird Request → MCP HTTPRequest
        let mcpRequest = try await convertToMCPRequest(request)

        // Route through session manager
        let mcpResponse = await handleHTTPRequest(mcpRequest)

        // Convert MCP HTTPResponse → Hummingbird Response
        return convertToHBResponse(mcpResponse)
    }

    // MARK: - Session Routing (adapted from MCP SDK HTTPApp pattern)

    private func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        // Route to existing session
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)

            // Clean up on successful DELETE
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
            }
            return response
        }

        // No session — check for initialize request
        if request.method.uppercased() == "POST",
           let body = request.body,
           isInitializeRequest(body) {
            return await createSessionAndHandle(request)
        }

        // No session and not initialize
        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")
        )
    }

    // MARK: - Session Management

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID)
        )

        let server = Server(
            name: "RuntimeViewer",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await toolRegistry.registerTools(on: server)

        do {
            try await server.start(transport: transport)

            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date()
            )

            let response = await transport.handleRequest(request)

            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }

            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create session: \(error.localizedDescription)")
            )
        }
    }

    private func sessionCleanupLoop() async {
        let timeout: TimeInterval = 3600 // 1 hour
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            let now = Date()
            let expired = sessions.filter { now.timeIntervalSince($0.value.lastAccessedAt) > timeout }
            for (sessionID, session) in expired {
                logger.info("Session expired: \(sessionID)")
                await session.transport.disconnect()
                sessions.removeValue(forKey: sessionID)
            }
        }
    }

    // MARK: - Request/Response Conversion

    private func convertToMCPRequest(_ request: Request) async throws -> HTTPRequest {
        var headers: [String: String] = [:]
        for field in request.headers {
            headers[field.name.rawName] = field.value
        }

        let bodyBuffer = try await request.body.collect(upTo: 10_000_000)
        let bodyData = bodyBuffer.readableBytes > 0 ? Data(buffer: bodyBuffer) : nil

        return HTTPRequest(
            method: request.method.rawValue,
            headers: headers,
            body: bodyData
        )
    }

    private func convertToHBResponse(_ mcpResponse: HTTPResponse) -> Response {
        var hbHeaders = HTTPFields()
        for (key, value) in mcpResponse.headers {
            if let name = HTTPField.Name(key) {
                hbHeaders.append(HTTPField(name: name, value: value))
            }
        }

        switch mcpResponse {
        case .stream(let sseStream, _):
            let mappedStream = sseStream.map { data -> ByteBuffer in
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                return buffer
            }
            return Response(
                status: .init(code: mcpResponse.statusCode),
                headers: hbHeaders,
                body: .init(asyncSequence: mappedStream)
            )

        default:
            if let bodyData = mcpResponse.bodyData {
                var buffer = ByteBufferAllocator().buffer(capacity: bodyData.count)
                buffer.writeBytes(bodyData)
                return Response(
                    status: .init(code: mcpResponse.statusCode),
                    headers: hbHeaders,
                    body: .init(byteBuffer: buffer)
                )
            } else {
                return Response(
                    status: .init(code: mcpResponse.statusCode),
                    headers: hbHeaders,
                    body: .init()
                )
            }
        }
    }

    // MARK: - Helpers

    private func isInitializeRequest(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else { return false }
        return method == "initialize"
    }

    private func writePortFile(port: UInt16) {
        do {
            try "\(port)".write(toFile: portFilePath, atomically: true, encoding: .utf8)
            logger.info("Wrote MCP HTTP port \(port) to \(self.portFilePath)")
        } catch {
            logger.error("Failed to write port file: \(error)")
        }
    }

    private nonisolated func removePortFile() {
        try? FileManager.default.removeItem(atPath: portFilePath)
    }
}
```

**Important implementation notes:**

1. Hummingbird API might need adjustments — use `context7` MCP tool or `DocumentationSearch` to verify exact Hummingbird 2.x `Application` init signature, `Router` handler signatures, `Request.headers` iteration, and `HTTPFields` construction.

2. The `NIOCore` import is needed for `ByteBuffer` and `ByteBufferAllocator`.

3. `HTTPField.Name` — Hummingbird 2.x uses `swift-http-types`. Custom MCP headers like `Mcp-Session-Id` might need `HTTPField.Name(_:)` which returns optional. Handle gracefully.

4. The `onServerRunning` callback + `withCheckedContinuation` pattern for getting the dynamic port is adapted from Hummingbird's test infrastructure.

**Step 2: Build to verify**

```bash
cd RuntimeViewerMCP && swift build 2>&1 | xcsift
```

Fix any Hummingbird API discrepancies (method signatures, type names).

**Step 3: Commit**

```bash
git add RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/MCPHTTPServer.swift
git commit -m "feat(mcp): add MCPHTTPServer with Hummingbird + multi-session support"
```

---

## Task 5: Update AppDelegate — Wire Up MCPHTTPServer

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift`

**Step 1: Replace MCPBridgeServer startup with MCPHTTPServer**

Find the MCP-related code in AppDelegate and replace:

```swift
// BEFORE:
private var mcpBridgeServer: MCPBridgeServer?

private func startMCPBridgeServer() {
    Task { @MainActor in
        do {
            let windowProvider = AppMCPBridgeWindowProvider()
            let server = try MCPBridgeServer(windowProvider: windowProvider)
            mcpBridgeServer = server
            await server.start()
        } catch {
            #log(.error, "Failed to start MCP Bridge Server: \(error, privacy: .public)")
        }
    }
}

// applicationWillTerminate:
mcpBridgeServer?.stop()


// AFTER:
private var mcpHTTPServer: MCPHTTPServer?

private func startMCPHTTPServer() {
    Task { @MainActor in
        do {
            let windowProvider = AppMCPBridgeWindowProvider()
            let bridgeServer = MCPBridgeServer(windowProvider: windowProvider)
            let httpServer = try MCPHTTPServer(bridgeServer: bridgeServer)
            mcpHTTPServer = httpServer
            try await httpServer.start()
        } catch {
            #log(.error, "Failed to start MCP HTTP Server: \(error, privacy: .public)")
        }
    }
}

// applicationWillTerminate:
mcpHTTPServer?.stop()
```

Also update `applicationDidFinishLaunching` to call `startMCPHTTPServer()` instead of `startMCPBridgeServer()`.

**Step 2: Build via Xcode**

Build the `RuntimeViewerUsingAppKit` scheme in Xcode to verify the app target compiles with the new MCPHTTPServer.

```bash
xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

**Step 3: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift
git commit -m "feat(mcp): switch AppDelegate to MCPHTTPServer"
```

---

## Task 6: Remove Obsolete MCP Server Code

**Files:**
- Delete: `RuntimeViewerUsingAppKit/RuntimeViewerMCPServer/main.swift`
- Delete: `RuntimeViewerUsingAppKit/RuntimeViewerMCPServer/MCPBridgeClient.swift`
- Delete: `RuntimeViewerUsingAppKit/RuntimeViewerMCPServer/MCPBridgeConnection.swift`
- Modify: Xcode project (remove RuntimeViewerMCPServer target + swift-sdk package dependency)

**Step 1: Delete MCP Server executable source files**

```bash
rm -rf RuntimeViewerUsingAppKit/RuntimeViewerMCPServer/
```

**Step 2: Update Xcode project**

This step requires careful manual editing or using Xcode:

1. Open the Xcode project
2. Remove the `RuntimeViewerMCPServer` target
3. Remove the Xcode-level `swift-sdk` package dependency (it's now in the SPM package)
4. Verify the main app target still links `RuntimeViewerMCPBridge` from the local SPM package

Alternatively, edit `project.pbxproj` to:
- Remove all `RuntimeViewerMCPServer` target references
- Remove `XCRemoteSwiftPackageReference "swift-sdk"` (Xcode-level)
- Remove file references for deleted files

**Step 3: Build to verify**

```bash
xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

**Step 4: Commit**

```bash
git add -A
git commit -m "chore(mcp): remove obsolete MCP Server process and bridge TCP code"
```

---

## Task 7: Final Verification

**Step 1: Clean build**

```bash
cd RuntimeViewerMCP && rm -rf .build && swift build 2>&1 | xcsift
```

**Step 2: Full app build**

```bash
xcodebuild clean build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

**Step 3: Manual smoke test**

1. Launch RuntimeViewerApp
2. Verify port file is created at `~/Library/Application Support/RuntimeViewer/mcp-http-port`
3. Read the port number from the file
4. Test with curl:
```bash
PORT=$(cat ~/Library/Application\ Support/RuntimeViewer/mcp-http-port)
curl -X POST http://127.0.0.1:$PORT/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Protocol-Version: 2025-03-26" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```
4. Verify SSE response stream with session ID header

**Step 4: Final commit**

If any fixes were needed during verification, commit them.

---

## Summary of File Changes

### New Files
| File | Purpose |
|------|---------|
| `RuntimeViewerMCPBridge/MCPBridgeProtocol.swift` | Data model types (moved from MCPShared) |
| `RuntimeViewerMCPBridge/MCPToolRegistry.swift` | Tool definitions + handler registration |
| `RuntimeViewerMCPBridge/MCPHTTPServer.swift` | Hummingbird HTTP server + session management |

### Modified Files
| File | Changes |
|------|---------|
| `RuntimeViewerMCP/Package.swift` | Add MCP SDK + Hummingbird deps, remove MCPShared target |
| `RuntimeViewerMCPBridge/MCPBridgeServer.swift` | Remove listener, make handles public |
| `AppDelegate.swift` | Switch from MCPBridgeServer to MCPHTTPServer |

### Deleted Files
| File | Reason |
|------|--------|
| `RuntimeViewerMCPShared/MCPBridgeProtocol.swift` | Moved to MCPBridge |
| `RuntimeViewerMCPShared/MCPBridgeTransport.swift` | TCP frame encoding obsolete |
| `RuntimeViewerMCPBridge/MCPBridgeListener.swift` | TCP listener replaced by Hummingbird |
| `RuntimeViewerMCPServer/main.swift` | Separate process eliminated |
| `RuntimeViewerMCPServer/MCPBridgeClient.swift` | Bridge client eliminated |
| `RuntimeViewerMCPServer/MCPBridgeConnection.swift` | Bridge connection eliminated |
