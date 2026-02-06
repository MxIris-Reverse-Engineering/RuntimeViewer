import Foundation
import MCP
import RuntimeViewerMCPShared

// MARK: - Tool Definitions

let getSelectedTypeTool = Tool(
    name: "get_selected_type",
    description: "Returns the currently selected type in the RuntimeViewer UI, including its image path, type name, kind, and full interface text.",
    inputSchema: .object([
        "type": .string("object"),
    ])
)

let getTypeInterfaceTool = Tool(
    name: "get_type_interface",
    description: "Gets the interface declaration for a specific runtime type in a given image. Returns the type's full interface text including methods, properties, and protocol conformances.",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "image_path": .object([
                "type": .string("string"),
                "description": .string("The full path of the image (framework/dylib) containing the type"),
            ]),
            "type_name": .object([
                "type": .string("string"),
                "description": .string("The name of the type to inspect (e.g. 'NSView', 'UIViewController')"),
            ]),
        ]),
        "required": .array([.string("image_path"), .string("type_name")]),
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
    .init(tools: [getSelectedTypeTool, getTypeInterfaceTool])
}

// Lazily connect to bridge when first tool call happens
actor BridgeConnection {
    private var client: MCPBridgeClient?

    func getClient() async throws -> MCPBridgeClient {
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

// Register tool call handler
await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case "get_selected_type":
        let client: MCPBridgeClient
        do {
            client = try await bridge.getClient()
        } catch {
            return .init(
                content: [.text("Error: RuntimeViewer app is not running or MCP bridge is not started. Please launch RuntimeViewer first. (\(error.localizedDescription))")],
                isError: true
            )
        }

        do {
            let response = try await client.getSelectedType()

            guard let typeName = response.typeName else {
                return .init(content: [.text("No type is currently selected in RuntimeViewer.")], isError: false)
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

    case "get_type_interface":
        guard let imagePath = params.arguments?["image_path"]?.stringValue,
              let typeName = params.arguments?["type_name"]?.stringValue else {
            return .init(
                content: [.text("Error: Both 'image_path' and 'type_name' parameters are required.")],
                isError: true
            )
        }

        let client: MCPBridgeClient
        do {
            client = try await bridge.getClient()
        } catch {
            return .init(
                content: [.text("Error: RuntimeViewer app is not running or MCP bridge is not started. Please launch RuntimeViewer first. (\(error.localizedDescription))")],
                isError: true
            )
        }

        do {
            let response = try await client.getTypeInterface(imagePath: imagePath, typeName: typeName)

            if let error = response.error {
                return .init(content: [.text("Error: \(error)")], isError: true)
            }

            var text = "Type: \(response.displayName ?? typeName)\n"
            if let kind = response.typeKind {
                text += "Kind: \(kind)\n"
            }
            text += "Image: \(imagePath)\n"
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

    default:
        throw MCPError.invalidParams("Unknown tool: \(params.name)")
    }
}

// Start MCP server with stdio transport
let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
