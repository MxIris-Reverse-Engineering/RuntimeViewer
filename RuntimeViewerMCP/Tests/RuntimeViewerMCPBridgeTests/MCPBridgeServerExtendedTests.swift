import Testing
import Foundation
import RuntimeViewerCore
@testable import RuntimeViewerMCPBridge

@Suite("MCPBridgeServer Extended")
struct MCPBridgeServerExtendedTests {
    // MARK: - Helpers

    private func makeProvider(with contexts: [MCPBridgeDocumentContext] = []) -> MockMCPBridgeDocumentProvider {
        let provider = MockMCPBridgeDocumentProvider()
        provider.contexts = contexts
        return provider
    }

    private func makeContext(
        identifier: String,
        displayName: String? = nil,
        isKeyWindow: Bool = true,
        selectedObject: RuntimeObject? = nil,
        selectedImageNode: RuntimeImageNode? = nil
    ) -> MCPBridgeDocumentContext {
        MCPBridgeDocumentContext(
            identifier: identifier,
            displayName: displayName,
            isKeyWindow: isKeyWindow,
            selectedRuntimeObject: selectedObject,
            selectedImageNode: selectedImageNode,
            runtimeEngine: .local
        )
    }

    private func makeObject(
        name: String = "TestClass",
        displayName: String? = nil,
        kind: RuntimeObjectKind = .objc(.type(.class)),
        imagePath: String = "/usr/lib/libobjc.A.dylib"
    ) -> RuntimeObject {
        RuntimeObject(
            name: name,
            displayName: displayName ?? name,
            kind: kind,
            secondaryKind: nil,
            imagePath: imagePath,
            children: []
        )
    }

    // MARK: - listWindows edge cases

    @Test("listWindows with single document")
    func listWindowsSingle() async {
        let provider = makeProvider(with: [makeContext(identifier: "solo", displayName: "Solo Doc")])
        let server = MCPBridgeServer(documentProvider: provider)
        let response = await server.listWindows()
        #expect(response.windows.count == 1)
        #expect(response.windows[0].identifier == "solo")
        #expect(response.windows[0].displayName == "Solo Doc")
    }

    @Test("listWindows with nil displayName")
    func listWindowsNilDisplayName() async {
        let provider = makeProvider(with: [makeContext(identifier: "doc", displayName: nil)])
        let server = MCPBridgeServer(documentProvider: provider)
        let response = await server.listWindows()
        #expect(response.windows[0].displayName == nil)
    }

    @Test("listWindows maps key window status correctly")
    func listWindowsKeyWindow() async {
        let provider = makeProvider(with: [
            makeContext(identifier: "key", isKeyWindow: true),
            makeContext(identifier: "nonkey", isKeyWindow: false),
        ])
        let server = MCPBridgeServer(documentProvider: provider)
        let response = await server.listWindows()
        #expect(response.windows.first(where: { $0.identifier == "key" })?.isKeyWindow == true)
        #expect(response.windows.first(where: { $0.identifier == "nonkey" })?.isKeyWindow == false)
    }

    @Test("listWindows with selected object includes type info")
    func listWindowsSelectedObject() async {
        let obj = makeObject(name: "UIButton", kind: .swift(.type(.class)), imagePath: "/System/Library/Frameworks/UIKit.framework/UIKit")
        let provider = makeProvider(with: [makeContext(identifier: "doc", selectedObject: obj)])
        let server = MCPBridgeServer(documentProvider: provider)
        let response = await server.listWindows()

        let window = response.windows[0]
        #expect(window.selectedTypeName == "UIButton")
        #expect(window.selectedTypeImagePath == obj.imagePath)
        #expect(window.selectedTypeImageName == "UIKit")
    }

    @Test("listWindows without selected object has nil type info")
    func listWindowsNoSelectedObject() async {
        let provider = makeProvider(with: [makeContext(identifier: "doc")])
        let server = MCPBridgeServer(documentProvider: provider)
        let response = await server.listWindows()
        #expect(response.windows[0].selectedTypeName == nil)
        #expect(response.windows[0].selectedTypeImagePath == nil)
        #expect(response.windows[0].selectedTypeImageName == nil)
    }

    // MARK: - selectedType

    @Test("selectedType throws MCPBridgeError when no object selected")
    func selectedTypeNoObjectSelected() async {
        let provider = makeProvider(with: [makeContext(identifier: "doc")])
        let server = MCPBridgeServer(documentProvider: provider)
        await #expect(throws: MCPBridgeError.self) {
            try await server.selectedType(windowIdentifier: "doc")
        }
    }

    @Test("selectedType throws for unknown window identifier")
    func selectedTypeUnknownWindow() async {
        let provider = makeProvider()
        let server = MCPBridgeServer(documentProvider: provider)
        await #expect(throws: MCPBridgeDocumentProviderError.self) {
            try await server.selectedType(windowIdentifier: "nonexistent")
        }
    }

    // MARK: - isObjectsLoaded edge cases

    @Test("isObjectsLoaded with valid document returns response")
    func isObjectsLoadedValid() async throws {
        let provider = makeProvider(with: [makeContext(identifier: "doc")])
        let server = MCPBridgeServer(documentProvider: provider)
        let response = try await server.isObjectsLoaded(windowIdentifier: "doc", imagePath: "/test")
        #expect(response.imagePath == "/test")
    }

    // MARK: - Multiple tools unknown window

    @Test("searchImages throws for unknown window")
    func searchImagesUnknownWindow() async {
        let provider = makeProvider()
        let server = MCPBridgeServer(documentProvider: provider)
        await #expect(throws: MCPBridgeDocumentProviderError.self) {
            try await server.searchImages(windowIdentifier: "bad", query: "test")
        }
    }

    @Test("isObjectsLoaded returns false for unknown path on fresh server")
    func isObjectsLoadedUnknownPath() async throws {
        let provider = makeProvider(with: [makeContext(identifier: "doc")])
        let server = MCPBridgeServer(documentProvider: provider)
        let response = try await server.isObjectsLoaded(windowIdentifier: "doc", imagePath: "/nonexistent/path")
        #expect(response.isLoaded == false)
        #expect(response.imagePath == "/nonexistent/path")
    }

    // MARK: - Server with many documents

    @Test("listWindows handles many documents")
    func listWindowsManyDocuments() async {
        let contexts = (0..<50).map { makeContext(identifier: "doc-\($0)", displayName: "Document \($0)", isKeyWindow: $0 == 0) }
        let provider = makeProvider(with: contexts)
        let server = MCPBridgeServer(documentProvider: provider)
        let response = await server.listWindows()
        #expect(response.windows.count == 50)
        #expect(response.windows.filter { $0.isKeyWindow }.count == 1)
    }

    // MARK: - MCPBridgeDocumentProviderError

    @Test("documentNotFound error includes identifier in description")
    func documentProviderErrorDescription() {
        let error = MCPBridgeDocumentProviderError.documentNotFound(identifier: "my-unique-doc-123")
        let description = error.errorDescription!
        #expect(description.contains("my-unique-doc-123"))
    }

    // MARK: - MCPBridgeDocumentContext

    @Test("MCPBridgeDocumentContext stores all fields")
    func contextStoresFields() {
        let obj = makeObject()
        let imageNode = RuntimeImageNode("test")
        let context = MCPBridgeDocumentContext(
            identifier: "ctx-1",
            displayName: "My Document",
            isKeyWindow: true,
            selectedRuntimeObject: obj,
            selectedImageNode: imageNode,
            runtimeEngine: .local
        )
        #expect(context.identifier == "ctx-1")
        #expect(context.displayName == "My Document")
        #expect(context.isKeyWindow == true)
        #expect(context.selectedRuntimeObject == obj)
        #expect(context.selectedImageNode?.name == "test")
    }

    @Test("MCPBridgeDocumentContext with nil optionals")
    func contextNilOptionals() {
        let context = MCPBridgeDocumentContext(
            identifier: "ctx-2",
            displayName: nil,
            isKeyWindow: false,
            selectedRuntimeObject: nil,
            selectedImageNode: nil,
            runtimeEngine: .local
        )
        #expect(context.displayName == nil)
        #expect(context.selectedRuntimeObject == nil)
        #expect(context.selectedImageNode == nil)
    }
}

// MARK: - MockMCPBridgeDocumentProvider tests

@Suite("MockMCPBridgeDocumentProvider")
struct MockMCPBridgeDocumentProviderTests {
    @Test("empty provider returns empty contexts")
    func emptyProvider() async {
        let provider = MockMCPBridgeDocumentProvider()
        let contexts = await provider.allDocumentContexts()
        #expect(contexts.isEmpty)
    }

    @Test("provider returns added contexts")
    func returnContexts() async {
        let provider = MockMCPBridgeDocumentProvider()
        provider.contexts = [
            MCPBridgeDocumentContext(
                identifier: "doc-1",
                displayName: "Doc 1",
                isKeyWindow: true,
                selectedRuntimeObject: nil,
                selectedImageNode: nil,
                runtimeEngine: .local
            ),
        ]
        let contexts = await provider.allDocumentContexts()
        #expect(contexts.count == 1)
        #expect(contexts[0].identifier == "doc-1")
    }

    @Test("provider finds context by identifier")
    func findByIdentifier() async throws {
        let provider = MockMCPBridgeDocumentProvider()
        provider.contexts = [
            MCPBridgeDocumentContext(identifier: "a", displayName: nil, isKeyWindow: false, selectedRuntimeObject: nil, selectedImageNode: nil, runtimeEngine: .local),
            MCPBridgeDocumentContext(identifier: "b", displayName: nil, isKeyWindow: true, selectedRuntimeObject: nil, selectedImageNode: nil, runtimeEngine: .local),
        ]
        let context = try await provider.documentContext(forIdentifier: "b")
        #expect(context.identifier == "b")
    }

    @Test("provider throws for unknown identifier")
    func throwsForUnknown() async {
        let provider = MockMCPBridgeDocumentProvider()
        await #expect(throws: MCPBridgeDocumentProviderError.self) {
            try await provider.documentContext(forIdentifier: "nonexistent")
        }
    }
}
