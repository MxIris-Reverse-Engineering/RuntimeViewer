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
                and the currently selected type's name, image path, and image name (if any). \
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
                Providing image_path or image_name restricts the search and is significantly faster; \
                omitting both searches all previously loaded images. \
                Use search_types first if you are unsure of the exact type name or image.
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
                        "description": .string("Full path of the image (framework/dylib) containing the type. Strongly recommended for faster lookup. If omitted, searches all loaded images. Mutually exclusive with image_name."),
                    ]),
                    "image_name": .object([
                        "type": .string("string"),
                        "description": .string("Short name of the image without path or extension (e.g. 'AppKit', 'UIKitCore', 'SwiftUI'). Case-insensitive. Use this when you don't know the full path. Mutually exclusive with image_path."),
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
                WARNING: omitting both image_path and image_name enumerates every type across all loaded images — \
                this can produce an extremely large response and trigger heavy I/O. Always provide image_path or image_name when possible. \
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
                        "description": .string("Full path of the image (framework/dylib) to list types from. Strongly recommended — omitting it dumps ALL loaded images which can be extremely large. Mutually exclusive with image_name."),
                    ]),
                    "image_name": .object([
                        "type": .string("string"),
                        "description": .string("Short name of the image without path or extension (e.g. 'AppKit', 'UIKitCore', 'SwiftUI'). Case-insensitive. Mutually exclusive with image_path."),
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
                Returns each match with its display name, kind, full image path, and image name. \
                This is the preferred way to locate a type when you do not know its exact name or image.
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
                        "description": .string("Restrict search to a specific image path. If omitted, searches all loaded images. Mutually exclusive with image_name."),
                    ]),
                    "image_name": .object([
                        "type": .string("string"),
                        "description": .string("Restrict search to images matching this short name (e.g. 'AppKit', 'UIKitCore'). Case-insensitive. Mutually exclusive with image_path."),
                    ]),
                ]),
                "required": .array([.string("window_identifier"), .string("query")]),
            ])
        ),
        Tool(
            name: "list_images",
            description: """
                Lists all image paths (frameworks, dylibs, executables) visible to the runtime, including images \
                that have not yet been loaded/parsed by RuntimeViewer. Returns the full file system path of every image \
                registered in dyld. Use this to discover available images before querying types with list_types, search_types, \
                or get_type_interface. To inspect types in an unloaded image, call load_image first.
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
            name: "search_images",
            description: """
                Searches all image paths (including unloaded) by case-insensitive substring matching. \
                Matches against the full path of each image visible to the runtime (e.g. searching 'UIKit' matches \
                '/System/Library/Frameworks/UIKit.framework/UIKit'). \
                Returns matching image paths sorted alphabetically. \
                Use this to find the correct image_path before calling other tools like list_types or get_type_interface. \
                To inspect types in an unloaded image, call load_image first.
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
                        "description": .string("Case-insensitive substring to match against image paths (e.g. 'AppKit', 'UIKit', 'SwiftUI', 'Foundation')"),
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
                        "description": .string("Full path of the image (framework/dylib) containing the type. Recommended for faster lookup. Mutually exclusive with image_name."),
                    ]),
                    "image_name": .object([
                        "type": .string("string"),
                        "description": .string("Short name of the image without path or extension (e.g. 'AppKit', 'UIKitCore'). Case-insensitive. Mutually exclusive with image_path."),
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
        Tool(
            name: "load_image",
            description: """
                Loads and parses an image (framework, dylib, executable) into RuntimeViewer. \
                Images listed by list_images or search_images may not yet be parsed by RuntimeViewer; calling this tool \
                triggers parsing of the image's ObjC/Swift metadata sections. \
                Set load_objects to true to also enumerate runtime objects (types) in a single call — \
                this is equivalent to calling load_image followed by load_objects. \
                Returns immediately if the image (and objects, if requested) are already loaded.
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
                        "description": .string("Full file system path of the image to load (as returned by list_images or search_images)"),
                    ]),
                    "load_objects": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, also enumerate and cache runtime objects (types) from this image after loading. Defaults to false."),
                    ]),
                ]),
                "required": .array([.string("window_identifier"), .string("image_path")]),
            ])
        ),
        Tool(
            name: "is_image_loaded",
            description: """
                Checks whether an image has been loaded and parsed by RuntimeViewer. \
                An image being in the dyld image list (returned by list_images) does NOT mean it has been parsed — \
                only images that have been explicitly loaded via load_image or accessed by other tools are considered loaded. \
                Use this to check before deciding whether to call load_image.
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
                        "description": .string("Full file system path of the image to check"),
                    ]),
                ]),
                "required": .array([.string("window_identifier"), .string("image_path")]),
            ])
        ),
        Tool(
            name: "load_objects",
            description: """
                Enumerates and caches all runtime objects (types) from a loaded image. \
                An image can be loaded (sections parsed) without its objects being enumerated. \
                This tool triggers the full object enumeration (ObjC classes, Swift types, etc.) and returns the count. \
                If the image is not yet loaded, it will be loaded automatically. \
                Once loaded, objects are available for list_types, search_types, get_type_interface, etc.
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
                        "description": .string("Full file system path of the image to load objects from"),
                    ]),
                ]),
                "required": .array([.string("window_identifier"), .string("image_path")]),
            ])
        ),
        Tool(
            name: "is_objects_loaded",
            description: """
                Checks whether runtime objects (types) have been enumerated for a given image. \
                Returns true only if load_objects (or load_image with load_objects=true) has been previously called \
                for this image in the current session. Use this to decide whether to call load_objects before \
                querying types with list_types, search_types, etc.
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
                        "description": .string("Full file system path of the image to check"),
                    ]),
                ]),
                "required": .array([.string("window_identifier"), .string("image_path")]),
            ])
        ),
    ]

    // MARK: - Server Registration

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
            let imageName = params.arguments?["image_name"]?.stringValue
            return try await handleTypeInterface(windowIdentifier: windowIdentifier, imagePath: imagePath, imageName: imageName, typeName: typeName, bridgeServer: bridgeServer)

        case "list_types":
            let windowIdentifier = try requireParam(params, "window_identifier")
            let imagePath = params.arguments?["image_path"]?.stringValue
            let imageName = params.arguments?["image_name"]?.stringValue
            return try await handleListTypes(windowIdentifier: windowIdentifier, imagePath: imagePath, imageName: imageName, bridgeServer: bridgeServer)

        case "search_types":
            let windowIdentifier = try requireParam(params, "window_identifier")
            let query = try requireParam(params, "query")
            let imagePath = params.arguments?["image_path"]?.stringValue
            let imageName = params.arguments?["image_name"]?.stringValue
            return try await handleSearchTypes(windowIdentifier: windowIdentifier, query: query, imagePath: imagePath, imageName: imageName, bridgeServer: bridgeServer)

        case "list_images":
            let windowIdentifier = try requireParam(params, "window_identifier")
            return try await handleListImages(windowIdentifier: windowIdentifier, bridgeServer: bridgeServer)

        case "search_images":
            let windowIdentifier = try requireParam(params, "window_identifier")
            let query = try requireParam(params, "query")
            return try await handleSearchImages(windowIdentifier: windowIdentifier, query: query, bridgeServer: bridgeServer)

        case "get_member_addresses":
            let windowIdentifier = try requireParam(params, "window_identifier")
            let typeName = try requireParam(params, "type_name")
            let imagePath = params.arguments?["image_path"]?.stringValue
            let imageName = params.arguments?["image_name"]?.stringValue
            let memberName = params.arguments?["member_name"]?.stringValue
            return try await handleMemberAddresses(windowIdentifier: windowIdentifier, imagePath: imagePath, imageName: imageName, typeName: typeName, memberName: memberName, bridgeServer: bridgeServer)

        case "load_image":
            let windowIdentifier = try requireParam(params, "window_identifier")
            let imagePath = try requireParam(params, "image_path")
            let loadObjects = params.arguments?["load_objects"]?.boolValue ?? false
            return try await handleLoadImage(windowIdentifier: windowIdentifier, imagePath: imagePath, loadObjects: loadObjects, bridgeServer: bridgeServer)

        case "is_image_loaded":
            let windowIdentifier = try requireParam(params, "window_identifier")
            let imagePath = try requireParam(params, "image_path")
            return try await handleIsImageLoaded(windowIdentifier: windowIdentifier, imagePath: imagePath, bridgeServer: bridgeServer)

        case "load_objects":
            let windowIdentifier = try requireParam(params, "window_identifier")
            let imagePath = try requireParam(params, "image_path")
            return try await handleLoadObjects(windowIdentifier: windowIdentifier, imagePath: imagePath, bridgeServer: bridgeServer)

        case "is_objects_loaded":
            let windowIdentifier = try requireParam(params, "window_identifier")
            let imagePath = try requireParam(params, "image_path")
            return try await handleIsObjectsLoaded(windowIdentifier: windowIdentifier, imagePath: imagePath, bridgeServer: bridgeServer)

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

    private static func handleListWindows(bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = await bridgeServer.handleListWindows()
        if response.windows.isEmpty {
            return .init(content: [.text("No RuntimeViewer windows are currently open.")])
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
                text += "\n  Selected Type Image Path: \(imagePath)"
            }
            if let imageName = window.selectedTypeImageName {
                text += "\n  Selected Type Image Name: \(imageName)"
            }
            text += "\n"
        }
        return .init(content: [.text(text)])
    }

    private static func handleSelectedType(windowIdentifier: String, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = try await bridgeServer.handleSelectedType(MCPSelectedTypeRequest(windowIdentifier: windowIdentifier))
        guard let typeName = response.typeName else {
            return .init(content: [.text("No type is currently selected in the specified window.")])
        }
        var text = "Selected Type:\n"
        text += "  Name: \(response.displayName ?? typeName)\n"
        if let kind = response.typeKind { text += "  Kind: \(kind)\n" }
        if let imageName = response.imageName { text += "  Image Name: \(imageName)\n" }
        if let imagePath = response.imagePath { text += "  Image Path: \(imagePath)\n" }
        if let interfaceText = response.interfaceText { text += "\nInterface:\n\(interfaceText)" }
        return .init(content: [.text(text)])
    }

    private static func handleTypeInterface(windowIdentifier: String, imagePath: String?, imageName: String?, typeName: String, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = try await bridgeServer.handleTypeInterface(MCPTypeInterfaceRequest(windowIdentifier: windowIdentifier, imagePath: imagePath, imageName: imageName, typeName: typeName))
        if let error = response.error {
            return .init(content: [.text("Error: \(error)")], isError: true)
        }
        var text = "Type: \(response.displayName ?? typeName)\n"
        if let kind = response.typeKind { text += "Kind: \(kind)\n" }
        if let responseImageName = response.imageName { text += "Image Name: \(responseImageName)\n" }
        if let responseImagePath = response.imagePath { text += "Image Path: \(responseImagePath)\n" }
        if let interfaceText = response.interfaceText {
            text += "\nInterface:\n\(interfaceText)"
        } else {
            text += "\nNo interface text available."
        }
        return .init(content: [.text(text)])
    }

    private static func handleListTypes(windowIdentifier: String, imagePath: String?, imageName: String?, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = try await bridgeServer.handleListTypes(MCPListTypesRequest(windowIdentifier: windowIdentifier, imagePath: imagePath, imageName: imageName))
        if let error = response.error {
            return .init(content: [.text("Error: \(error)")], isError: true)
        }
        if response.types.isEmpty {
            let scope = imagePath.map { "image '\($0)'" } ?? "all loaded images"
            return .init(content: [.text("No types found in \(scope).")])
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
        return .init(content: [.text(text)])
    }

    private static func handleSearchTypes(windowIdentifier: String, query: String, imagePath: String?, imageName: String?, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = try await bridgeServer.handleSearchTypes(MCPSearchTypesRequest(windowIdentifier: windowIdentifier, query: query, imagePath: imagePath, imageName: imageName))
        if let error = response.error {
            return .init(content: [.text("Error: \(error)")], isError: true)
        }
        if response.types.isEmpty {
            var text = "No types matching '\(query)'"
            if let imagePath { text += " in image '\(imagePath)'" }
            return .init(content: [.text(text + ".")])
        }
        var text = "Search results for '\(query)':\nFound \(response.types.count) matching types\n\n"
        for type in response.types {
            text += "  \(type.displayName) [\(type.kind)] — \(type.imageName)\n"
        }
        return .init(content: [.text(text)])
    }

    private static func handleListImages(windowIdentifier: String, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = try await bridgeServer.handleListImages(MCPListImagesRequest(windowIdentifier: windowIdentifier))
        if response.imagePaths.isEmpty {
            return .init(content: [.text("No images found in the runtime.")])
        }
        var text = "Runtime Images (\(response.imagePaths.count)):\n\n"
        for path in response.imagePaths {
            text += "  \(path)\n"
        }
        return .init(content: [.text(text)])
    }

    private static func handleSearchImages(windowIdentifier: String, query: String, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = try await bridgeServer.handleSearchImages(MCPSearchImagesRequest(windowIdentifier: windowIdentifier, query: query))
        if response.imagePaths.isEmpty {
            return .init(content: [.text("No images matching '\(query)'.")])
        }
        var text = "Images matching '\(query)' (\(response.imagePaths.count)):\n\n"
        for path in response.imagePaths {
            text += "  \(path)\n"
        }
        return .init(content: [.text(text)])
    }

    private static func handleMemberAddresses(windowIdentifier: String, imagePath: String?, imageName: String?, typeName: String, memberName: String?, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = try await bridgeServer.handleMemberAddresses(MCPMemberAddressesRequest(windowIdentifier: windowIdentifier, imagePath: imagePath, imageName: imageName, typeName: typeName, memberName: memberName))
        if let error = response.error {
            return .init(content: [.text("Error: \(error)")], isError: true)
        }
        if response.members.isEmpty {
            let filterNote = memberName.map { " matching '\($0)'" } ?? ""
            return .init(content: [.text("No member addresses found\(filterNote) for '\(typeName)'.")])
        }
        var text = "Member addresses for \(response.typeName ?? typeName):\n"
        if let memberName { text += "Filter: '\(memberName)'\n" }
        text += "Found \(response.members.count) member(s)\n\n"
        for member in response.members {
            text += "  [\(member.kind)] \(member.name)\n"
            text += "    Address:    \(member.address)\n"
            text += "    Symbol:     \(member.symbolName)\n"
        }
        return .init(content: [.text(text)])
    }

    private static func handleLoadImage(windowIdentifier: String, imagePath: String, loadObjects: Bool, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = try await bridgeServer.handleLoadImage(MCPLoadImageRequest(windowIdentifier: windowIdentifier, imagePath: imagePath, loadObjects: loadObjects))
        if let error = response.error {
            return .init(content: [.text("Error: \(error)")], isError: true)
        }
        var text = response.alreadyLoaded ? "Image already loaded" : "Successfully loaded image"
        text += ": \(response.imagePath)"
        if loadObjects {
            text += response.objectsLoaded ? " (objects loaded)" : " (objects not yet loaded)"
        }
        return .init(content: [.text(text)])
    }

    private static func handleIsImageLoaded(windowIdentifier: String, imagePath: String, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = try await bridgeServer.handleIsImageLoaded(MCPIsImageLoadedRequest(windowIdentifier: windowIdentifier, imagePath: imagePath))
        let status = response.isLoaded ? "loaded" : "not loaded"
        return .init(content: [.text("Image \(status): \(response.imagePath)")])
    }

    private static func handleLoadObjects(windowIdentifier: String, imagePath: String, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = try await bridgeServer.handleLoadObjects(MCPLoadObjectsRequest(windowIdentifier: windowIdentifier, imagePath: imagePath))
        if let error = response.error {
            return .init(content: [.text("Error: \(error)")], isError: true)
        }
        let status = response.alreadyLoaded ? "Objects already loaded" : "Successfully loaded objects"
        return .init(content: [.text("\(status) from \(response.imagePath): \(response.objectCount) types found")])
    }

    private static func handleIsObjectsLoaded(windowIdentifier: String, imagePath: String, bridgeServer: MCPBridgeServer) async throws -> CallTool.Result {
        let response = try await bridgeServer.handleIsObjectsLoaded(MCPIsObjectsLoadedRequest(windowIdentifier: windowIdentifier, imagePath: imagePath))
        let status = response.isLoaded ? "loaded" : "not loaded"
        return .init(content: [.text("Objects \(status) for image: \(response.imagePath)")])
    }
}
