import Foundation
import MCP
import RuntimeViewerMCPShared

// MARK: - Tool Definitions

let listWindowsTool = Tool(
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
)

let selectedTypeTool = Tool(
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
)

let typeInterfaceTool = Tool(
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
)

let listTypesTool = Tool(
    name: "list_types",
    description: """
        Lists all runtime types in an image, grouped by kind with a total count. \
        Returned kinds include: Objective-C Class, Objective-C Protocol, Objective-C Class Category, \
        Swift Class, Swift Struct, Swift Enum, Swift Protocol, Swift TypeAlias, \
        and their Extension/Conformance variants, as well as C Struct and C Union. \
        Each entry has a display name and kind. Results are flattened from the type hierarchy tree. \
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
)

let searchTypesTool = Tool(
    name: "search_types",
    description: """
        Searches for runtime types by name using case-insensitive substring matching against both \
        the internal name (mangled for Swift) and the display name (human-readable). \
        Returns each match with its display name, kind, and full image path. \
        This is the preferred way to locate a type when you do not know its exact name or image path. \
        Typical workflow: search_types to find the type → use the returned image_path and display name \
        with get_type_interface for efficient lookup.
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
)

//let grepTypeInterfaceTool = Tool(
//    name: "grep_type_interface",
//    description: "Searches through generated interface text of all types for a keyword pattern. Returns matching types with the lines that contain the pattern. Useful for finding types that declare specific methods, properties, or protocol conformances. If image_path is omitted, searches across all loaded images.",
//    inputSchema: .object([
//        "type": .string("object"),
//        "properties": .object([
//            "window_identifier": .object([
//                "type": .string("string"),
//                "description": .string("The window identifier obtained from list_windows"),
//            ]),
//            "image_path": .object([
//                "type": .string("string"),
//                "description": .string("Optional: the full path of the image (framework/dylib) to search in. If omitted, searches all loaded images."),
//            ]),
//            "pattern": .object([
//                "type": .string("string"),
//                "description": .string("The search pattern (case-insensitive substring match against interface text lines)"),
//            ]),
//        ]),
//        "required": .array([.string("window_identifier"), .string("pattern")]),
//    ])
//)

let memberAddressesTool = Tool(
    name: "get_member_addresses",
    description: """
        Returns runtime memory addresses of a type's members. Supports both Swift and Objective-C types (not C structs/unions). \
        For Swift types: returns functions, static functions, initializers, computed property accessors (getter/setter/modify/read), \
        and subscript accessors, with mangled symbol names and hex addresses. \
        For ObjC types (classes, protocols, categories): returns instance/class methods with their IMP addresses, \
        plus property getter and setter accessors (respects custom getter/setter names). \
        Members with a zero IMP (e.g. from the dyld shared cache) are excluded. \
        Each entry includes: kind, demangled/readable name, symbol name (e.g. "-[Class method]" for ObjC), and hex address. \
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
                "description": .string("The name of the type to inspect — works for both Swift (e.g. 'MyClass') and ObjC (e.g. 'NSView') types"),
            ]),
            "member_name": .object([
                "type": .string("string"),
                "description": .string("Filter to members whose name contains this string (case-insensitive substring match). If omitted, returns all members."),
            ]),
        ]),
        "required": .array([.string("window_identifier"), .string("type_name")]),
    ])
)

// MARK: - Main

let server = Server(
    name: "RuntimeViewer",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: false))
)

// Register tool list handler
await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: [listWindowsTool, selectedTypeTool, typeInterfaceTool, listTypesTool, searchTypesTool, /*grepTypeInterfaceTool,*/ memberAddressesTool])
}

// Lazily connect to bridge when first tool call happens
actor BridgeConnection {
    private var client: MCPBridgeClient?

    func connectedClient() async throws -> MCPBridgeClient {
        if let client {
            return client
        }
        let newClient = try await MCPBridgeClient.connectFromPortFile()
        self.client = newClient
        return newClient
    }

    func reset() {
        client?.stop()
        client = nil
    }
}

let bridge = BridgeConnection()

// Helper to get a connected client with error handling
enum BridgeResult {
    case connected(MCPBridgeClient)
    case error(CallTool.Result)
}

func connectedClient() async -> BridgeResult {
    do {
        let client = try await bridge.connectedClient()
        return .connected(client)
    } catch {
        return .error(.init(
            content: [.text("Error: RuntimeViewer app is not running or MCP bridge is not started. Please launch RuntimeViewer first. (\(error.localizedDescription))")],
            isError: true
        ))
    }
}

// Register tool call handler
await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case "list_windows":
        switch await connectedClient() {
        case .connected(let client):
            do {
                let response = try await client.listWindows()

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
            } catch {
                await bridge.reset()
                return .init(
                    content: [.text("Error communicating with RuntimeViewer: \(error.localizedDescription)")],
                    isError: true
                )
            }
        case .error(let errorResult):
            return errorResult
        }

    case "get_selected_type":
        guard let windowIdentifier = params.arguments?["window_identifier"]?.stringValue else {
            return .init(
                content: [.text("Error: 'window_identifier' parameter is required. Use list_windows to get available window identifiers.")],
                isError: true
            )
        }

        switch await connectedClient() {
        case .connected(let client):
            do {
                let response = try await client.selectedType(windowIdentifier: windowIdentifier)

                guard let typeName = response.typeName else {
                    return .init(content: [.text("No type is currently selected in the specified window.")], isError: false)
                }

                var text = "Selected Type:\n"
                text += "  Name: \(response.displayName ?? typeName)\n"
                if let kind = response.typeKind {
                    text += "  Kind: \(kind)\n"
                }
                if let imagePath = response.imagePath {
                    text += "  Image: \(imagePath)\n"
                }
                if let interfaceText = response.interfaceText {
                    text += "\nInterface:\n\(interfaceText)"
                }

                return .init(content: [.text(text)], isError: false)
            } catch {
                await bridge.reset()
                return .init(
                    content: [.text("Error communicating with RuntimeViewer: \(error.localizedDescription)")],
                    isError: true
                )
            }
        case .error(let errorResult):
            return errorResult
        }

    case "get_type_interface":
        guard let windowIdentifier = params.arguments?["window_identifier"]?.stringValue else {
            return .init(
                content: [.text("Error: 'window_identifier' parameter is required. Use list_windows to get available window identifiers.")],
                isError: true
            )
        }
        guard let typeName = params.arguments?["type_name"]?.stringValue else {
            return .init(
                content: [.text("Error: 'type_name' parameter is required.")],
                isError: true
            )
        }
        let imagePath = params.arguments?["image_path"]?.stringValue

        switch await connectedClient() {
        case .connected(let client):
            do {
                let response = try await client.typeInterface(windowIdentifier: windowIdentifier, imagePath: imagePath, typeName: typeName)

                if let error = response.error {
                    return .init(content: [.text("Error: \(error)")], isError: true)
                }

                var text = "Type: \(response.displayName ?? typeName)\n"
                if let kind = response.typeKind {
                    text += "Kind: \(kind)\n"
                }
                if let responseImagePath = response.imagePath {
                    text += "Image: \(responseImagePath)\n"
                }
                if let interfaceText = response.interfaceText {
                    text += "\nInterface:\n\(interfaceText)"
                } else {
                    text += "\nNo interface text available."
                }

                return .init(content: [.text(text)], isError: false)
            } catch {
                await bridge.reset()
                return .init(
                    content: [.text("Error communicating with RuntimeViewer: \(error.localizedDescription)")],
                    isError: true
                )
            }
        case .error(let errorResult):
            return errorResult
        }

    case "list_types":
        guard let windowIdentifier = params.arguments?["window_identifier"]?.stringValue else {
            return .init(
                content: [.text("Error: 'window_identifier' parameter is required. Use list_windows to get available window identifiers.")],
                isError: true
            )
        }
        let imagePath = params.arguments?["image_path"]?.stringValue

        switch await connectedClient() {
        case .connected(let client):
            do {
                let response = try await client.listTypes(windowIdentifier: windowIdentifier, imagePath: imagePath)

                if let error = response.error {
                    return .init(content: [.text("Error: \(error)")], isError: true)
                }

                if response.types.isEmpty {
                    let scope = imagePath.map { "image '\($0)'" } ?? "all loaded images"
                    return .init(content: [.text("No types found in \(scope).")], isError: false)
                }

                // Group types by kind
                var grouped: [String: [MCPRuntimeTypeInfo]] = [:]
                for type in response.types {
                    grouped[type.kind, default: []].append(type)
                }

                let scopeName: String
                if let imagePath {
                    scopeName = String(imagePath.split(separator: "/").last ?? Substring(imagePath))
                } else {
                    scopeName = "all loaded images"
                }
                var text = "Types in \(scopeName):\n"
                text += "Total: \(response.types.count) types\n"
                for (kind, types) in grouped.sorted(by: { $0.key < $1.key }) {
                    text += "\n[\(kind)] (\(types.count)):\n"
                    for type in types {
                        text += "  - \(type.displayName)\n"
                    }
                }

                return .init(content: [.text(text)], isError: false)
            } catch {
                await bridge.reset()
                return .init(
                    content: [.text("Error communicating with RuntimeViewer: \(error.localizedDescription)")],
                    isError: true
                )
            }
        case .error(let errorResult):
            return errorResult
        }

    case "search_types":
        guard let windowIdentifier = params.arguments?["window_identifier"]?.stringValue else {
            return .init(
                content: [.text("Error: 'window_identifier' parameter is required. Use list_windows to get available window identifiers.")],
                isError: true
            )
        }
        guard let query = params.arguments?["query"]?.stringValue else {
            return .init(
                content: [.text("Error: 'query' parameter is required.")],
                isError: true
            )
        }
        let imagePath = params.arguments?["image_path"]?.stringValue

        switch await connectedClient() {
        case .connected(let client):
            do {
                let response = try await client.searchTypes(windowIdentifier: windowIdentifier, query: query, imagePath: imagePath)

                if let error = response.error {
                    return .init(content: [.text("Error: \(error)")], isError: true)
                }

                if response.types.isEmpty {
                    var text = "No types matching '\(query)'"
                    if let imagePath {
                        text += " in image '\(imagePath)'"
                    }
                    text += "."
                    return .init(content: [.text(text)], isError: false)
                }

                var text = "Search results for '\(query)':\n"
                text += "Found \(response.types.count) matching types\n\n"
                for type in response.types {
                    let imageName = type.imagePath.split(separator: "/").last ?? Substring(type.imagePath)
                    text += "  \(type.displayName) [\(type.kind)] — \(imageName)\n"
                }

                return .init(content: [.text(text)], isError: false)
            } catch {
                await bridge.reset()
                return .init(
                    content: [.text("Error communicating with RuntimeViewer: \(error.localizedDescription)")],
                    isError: true
                )
            }
        case .error(let errorResult):
            return errorResult
        }

    case "grep_type_interface":
        guard let windowIdentifier = params.arguments?["window_identifier"]?.stringValue else {
            return .init(
                content: [.text("Error: 'window_identifier' parameter is required. Use list_windows to get available window identifiers.")],
                isError: true
            )
        }
        let imagePath = params.arguments?["image_path"]?.stringValue
        guard let pattern = params.arguments?["pattern"]?.stringValue else {
            return .init(
                content: [.text("Error: 'pattern' parameter is required.")],
                isError: true
            )
        }

        switch await connectedClient() {
        case .connected(let client):
            do {
                let response = try await client.grepTypeInterface(windowIdentifier: windowIdentifier, imagePath: imagePath, pattern: pattern)

                if let error = response.error {
                    return .init(content: [.text("Error: \(error)")], isError: true)
                }

                if response.matches.isEmpty {
                    let scope = imagePath.map { "image '\($0)'" } ?? "all loaded images"
                    return .init(content: [.text("No matches for '\(pattern)' in \(scope).")], isError: false)
                }

                let scopeName: String
                if let imagePath {
                    scopeName = String(imagePath.split(separator: "/").last ?? Substring(imagePath))
                } else {
                    scopeName = "all loaded images"
                }
                var text = "Grep results for '\(pattern)' in \(scopeName):\n"
                text += "Found matches in \(response.matches.count) types\n"
                for match in response.matches {
                    text += "\n--- \(match.typeName) [\(match.kind)] ---\n"
                    for line in match.matchingLines {
                        text += "  \(line)\n"
                    }
                }

                return .init(content: [.text(text)], isError: false)
            } catch {
                await bridge.reset()
                return .init(
                    content: [.text("Error communicating with RuntimeViewer: \(error.localizedDescription)")],
                    isError: true
                )
            }
        case .error(let errorResult):
            return errorResult
        }

    case "get_member_addresses":
        guard let windowIdentifier = params.arguments?["window_identifier"]?.stringValue else {
            return .init(
                content: [.text("Error: 'window_identifier' parameter is required. Use list_windows to get available window identifiers.")],
                isError: true
            )
        }
        guard let typeName = params.arguments?["type_name"]?.stringValue else {
            return .init(
                content: [.text("Error: 'type_name' parameter is required.")],
                isError: true
            )
        }
        let imagePath = params.arguments?["image_path"]?.stringValue
        let memberName = params.arguments?["member_name"]?.stringValue

        switch await connectedClient() {
        case .connected(let client):
            do {
                let response = try await client.memberAddresses(windowIdentifier: windowIdentifier, imagePath: imagePath, typeName: typeName, memberName: memberName)

                if let error = response.error {
                    return .init(content: [.text("Error: \(error)")], isError: true)
                }

                if response.members.isEmpty {
                    let filterNote = memberName.map { " matching '\($0)'" } ?? ""
                    return .init(content: [.text("No member addresses found\(filterNote) for '\(typeName)'. This may not be a Swift type, or the type has no functions/computed properties with symbols.")], isError: false)
                }

                var text = "Member addresses for \(response.typeName ?? typeName):\n"
                if let memberName {
                    text += "Filter: '\(memberName)'\n"
                }
                text += "Found \(response.members.count) member(s)\n\n"
                for member in response.members {
                    text += "  [\(member.kind)] \(member.name)\n"
                    text += "    Address:    \(member.address)\n"
                    text += "    Symbol:     \(member.symbolName)\n"
                }

                return .init(content: [.text(text)], isError: false)
            } catch {
                await bridge.reset()
                return .init(
                    content: [.text("Error communicating with RuntimeViewer: \(error.localizedDescription)")],
                    isError: true
                )
            }
        case .error(let errorResult):
            return errorResult
        }

    default:
        throw MCPError.invalidParams("Unknown tool: \(params.name)")
    }
}

// Start MCP server with stdio transport
let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
