import Testing
import RuntimeViewerCore
@testable import RuntimeViewerMCPBridge

@Suite("MCPBridgeServer")
struct MCPBridgeServerTests {
    // MARK: - listWindows

    @Test("listWindows returns empty when no documents")
    func listWindowsEmpty() async {
        let provider = MockMCPBridgeDocumentProvider()
        let server = MCPBridgeServer(documentProvider: provider)
        let response = await server.listWindows()
        #expect(response.windows.isEmpty)
    }

    @Test("listWindows returns all document contexts as window info")
    func listWindowsMultiple() async {
        let provider = MockMCPBridgeDocumentProvider()
        let engine = RuntimeEngine.local
        provider.contexts = [
            MCPBridgeDocumentContext(
                identifier: "doc-1",
                displayName: "Document 1",
                isKeyWindow: true,
                selectedRuntimeObject: nil,
                selectedImageNode: nil,
                runtimeEngine: engine
            ),
            MCPBridgeDocumentContext(
                identifier: "doc-2",
                displayName: "Document 2",
                isKeyWindow: false,
                selectedRuntimeObject: nil,
                selectedImageNode: nil,
                runtimeEngine: engine
            ),
        ]
        let server = MCPBridgeServer(documentProvider: provider)
        let response = await server.listWindows()

        #expect(response.windows.count == 2)
        #expect(response.windows[0].identifier == "doc-1")
        #expect(response.windows[0].displayName == "Document 1")
        #expect(response.windows[0].isKeyWindow == true)
        #expect(response.windows[1].identifier == "doc-2")
        #expect(response.windows[1].isKeyWindow == false)
    }

    @Test("listWindows includes selected type info from RuntimeObject")
    func listWindowsWithSelectedType() async {
        let provider = MockMCPBridgeDocumentProvider()
        let engine = RuntimeEngine.local
        let selectedObject = RuntimeObject(
            name: "NSView",
            displayName: "NSView",
            kind: .objc(.type(.class)),
            secondaryKind: nil,
            imagePath: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            children: []
        )
        provider.contexts = [
            MCPBridgeDocumentContext(
                identifier: "doc-1",
                displayName: nil,
                isKeyWindow: true,
                selectedRuntimeObject: selectedObject,
                selectedImageNode: nil,
                runtimeEngine: engine
            ),
        ]
        let server = MCPBridgeServer(documentProvider: provider)
        let response = await server.listWindows()

        #expect(response.windows.count == 1)
        #expect(response.windows[0].selectedTypeName == "NSView")
        #expect(response.windows[0].selectedTypeImagePath == selectedObject.imagePath)
        #expect(response.windows[0].selectedTypeImageName == selectedObject.imageName)
    }

    // MARK: - selectedType

    @Test("selectedType throws when document not found")
    func selectedTypeDocumentNotFound() async {
        let provider = MockMCPBridgeDocumentProvider()
        let server = MCPBridgeServer(documentProvider: provider)

        await #expect(throws: MCPBridgeDocumentProviderError.self) {
            try await server.selectedType(windowIdentifier: "nonexistent")
        }
    }

    @Test("selectedType throws when no type is selected")
    func selectedTypeNoSelection() async {
        let provider = MockMCPBridgeDocumentProvider()
        let engine = RuntimeEngine.local
        provider.contexts = [
            MCPBridgeDocumentContext(
                identifier: "doc-1",
                displayName: nil,
                isKeyWindow: true,
                selectedRuntimeObject: nil,
                selectedImageNode: nil,
                runtimeEngine: engine
            ),
        ]
        let server = MCPBridgeServer(documentProvider: provider)

        await #expect(throws: MCPBridgeError.self) {
            try await server.selectedType(windowIdentifier: "doc-1")
        }
    }

    // MARK: - isObjectsLoaded

    @Test("isObjectsLoaded returns false for fresh server")
    func isObjectsLoadedFresh() async throws {
        let provider = MockMCPBridgeDocumentProvider()
        let engine = RuntimeEngine.local
        provider.contexts = [
            MCPBridgeDocumentContext(
                identifier: "doc-1",
                displayName: nil,
                isKeyWindow: true,
                selectedRuntimeObject: nil,
                selectedImageNode: nil,
                runtimeEngine: engine
            ),
        ]
        let server = MCPBridgeServer(documentProvider: provider)
        let response = try await server.isObjectsLoaded(windowIdentifier: "doc-1", imagePath: "/some/path")

        #expect(response.imagePath == "/some/path")
        #expect(response.isLoaded == false)
    }

    // MARK: - searchImages

    @Test("searchImages throws when no images match query")
    func searchImagesNoMatch() async {
        let provider = MockMCPBridgeDocumentProvider()
        let engine = RuntimeEngine.local
        provider.contexts = [
            MCPBridgeDocumentContext(
                identifier: "doc-1",
                displayName: nil,
                isKeyWindow: true,
                selectedRuntimeObject: nil,
                selectedImageNode: nil,
                runtimeEngine: engine
            ),
        ]
        let server = MCPBridgeServer(documentProvider: provider)

        await #expect(throws: MCPBridgeError.self) {
            try await server.searchImages(windowIdentifier: "doc-1", query: "ThisFrameworkDoesNotExist_XYZ_12345")
        }
    }

    // MARK: - Tool methods with invalid window identifier

    @Test("typeInterface throws for unknown window")
    func typeInterfaceUnknownWindow() async {
        let provider = MockMCPBridgeDocumentProvider()
        let server = MCPBridgeServer(documentProvider: provider)

        await #expect(throws: MCPBridgeDocumentProviderError.self) {
            try await server.typeInterface(windowIdentifier: "bad-id", typeName: "NSObject")
        }
    }

    @Test("listTypes throws for unknown window")
    func listTypesUnknownWindow() async {
        let provider = MockMCPBridgeDocumentProvider()
        let server = MCPBridgeServer(documentProvider: provider)

        await #expect(throws: MCPBridgeDocumentProviderError.self) {
            try await server.listTypes(windowIdentifier: "bad-id")
        }
    }

    @Test("searchTypes throws for unknown window")
    func searchTypesUnknownWindow() async {
        let provider = MockMCPBridgeDocumentProvider()
        let server = MCPBridgeServer(documentProvider: provider)

        await #expect(throws: MCPBridgeDocumentProviderError.self) {
            try await server.searchTypes(windowIdentifier: "bad-id", query: "test")
        }
    }

    @Test("listImages throws for unknown window")
    func listImagesUnknownWindow() async {
        let provider = MockMCPBridgeDocumentProvider()
        let server = MCPBridgeServer(documentProvider: provider)

        await #expect(throws: MCPBridgeDocumentProviderError.self) {
            try await server.listImages(windowIdentifier: "bad-id")
        }
    }

    @Test("memberAddresses throws for unknown window")
    func memberAddressesUnknownWindow() async {
        let provider = MockMCPBridgeDocumentProvider()
        let server = MCPBridgeServer(documentProvider: provider)

        await #expect(throws: MCPBridgeDocumentProviderError.self) {
            try await server.memberAddresses(windowIdentifier: "bad-id", typeName: "NSObject")
        }
    }

    @Test("loadImage throws for unknown window")
    func loadImageUnknownWindow() async {
        let provider = MockMCPBridgeDocumentProvider()
        let server = MCPBridgeServer(documentProvider: provider)

        await #expect(throws: MCPBridgeDocumentProviderError.self) {
            try await server.loadImage(windowIdentifier: "bad-id", imagePath: "/path")
        }
    }

    @Test("loadObjects throws for unknown window")
    func loadObjectsUnknownWindow() async {
        let provider = MockMCPBridgeDocumentProvider()
        let server = MCPBridgeServer(documentProvider: provider)

        await #expect(throws: MCPBridgeDocumentProviderError.self) {
            try await server.loadObjects(windowIdentifier: "bad-id", imagePath: "/path")
        }
    }

    @Test("isImageLoaded throws for unknown window")
    func isImageLoadedUnknownWindow() async {
        let provider = MockMCPBridgeDocumentProvider()
        let server = MCPBridgeServer(documentProvider: provider)

        await #expect(throws: MCPBridgeDocumentProviderError.self) {
            try await server.isImageLoaded(windowIdentifier: "bad-id", imagePath: "/path")
        }
    }
}
