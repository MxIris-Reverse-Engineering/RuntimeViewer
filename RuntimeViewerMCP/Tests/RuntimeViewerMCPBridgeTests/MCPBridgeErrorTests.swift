import Testing
@testable import RuntimeViewerMCPBridge

@Suite("MCPBridgeError")
struct MCPBridgeErrorTests {
    @Test("noTypeSelected has descriptive message")
    func noTypeSelected() {
        let error = MCPBridgeError.noTypeSelected
        let description = error.errorDescription
        #expect(description != nil)
        #expect(description!.contains("No type"))
    }

    @Test("typeNotFound includes type name and scope")
    func typeNotFound() {
        let error = MCPBridgeError.typeNotFound(name: "NSView", scope: "AppKit")
        let description = error.errorDescription!
        #expect(description.contains("NSView"))
        #expect(description.contains("AppKit"))
    }

    @Test("imageNotLoaded includes path")
    func imageNotLoaded() {
        let error = MCPBridgeError.imageNotLoaded(path: "/usr/lib/libobjc.A.dylib")
        let description = error.errorDescription!
        #expect(description.contains("/usr/lib/libobjc.A.dylib"))
    }

    @Test("imageNotFound includes name")
    func imageNotFound() {
        let error = MCPBridgeError.imageNotFound(name: "AppKit")
        let description = error.errorDescription!
        #expect(description.contains("AppKit"))
    }

    @Test("imageLoadFailed includes path and reason")
    func imageLoadFailed() {
        let error = MCPBridgeError.imageLoadFailed(path: "/invalid/path", reason: "file not found")
        let description = error.errorDescription!
        #expect(description.contains("/invalid/path"))
        #expect(description.contains("file not found"))
    }

    @Test("noImagesLoaded has descriptive message")
    func noImagesLoaded() {
        let error = MCPBridgeError.noImagesLoaded
        let description = error.errorDescription
        #expect(description != nil)
        #expect(description!.contains("No images"))
    }

    @Test("noMatchingImages includes query")
    func noMatchingImages() {
        let error = MCPBridgeError.noMatchingImages(query: "UIKit")
        let description = error.errorDescription!
        #expect(description.contains("UIKit"))
    }

    @Test("noTypesFound includes scope")
    func noTypesFound() {
        let error = MCPBridgeError.noTypesFound(scope: "Foundation")
        let description = error.errorDescription!
        #expect(description.contains("Foundation"))
    }

    @Test("interfaceGenerationFailed includes type name and reason")
    func interfaceGenerationFailed() {
        let error = MCPBridgeError.interfaceGenerationFailed(typeName: "NSObject", reason: "parse error")
        let description = error.errorDescription!
        #expect(description.contains("NSObject"))
        #expect(description.contains("parse error"))
    }

    @Test("operationFailed returns custom message")
    func operationFailed() {
        let message = "Something went wrong"
        let error = MCPBridgeError.operationFailed(message)
        #expect(error.errorDescription == message)
    }

    @Test("all error cases produce non-nil errorDescription", arguments: [
        MCPBridgeError.noTypeSelected,
        .typeNotFound(name: "X", scope: "Y"),
        .imageNotLoaded(path: "/path"),
        .imageNotFound(name: "name"),
        .imageLoadFailed(path: "/path", reason: "reason"),
        .noImagesLoaded,
        .noMatchingImages(query: "query"),
        .noTypesFound(scope: "scope"),
        .interfaceGenerationFailed(typeName: "type", reason: "reason"),
        .operationFailed("msg"),
    ])
    func allCasesHaveDescription(error: MCPBridgeError) {
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
    }
}

@Suite("MCPBridgeDocumentProviderError")
struct MCPBridgeDocumentProviderErrorTests {
    @Test("documentNotFound includes identifier")
    func documentNotFound() {
        let error = MCPBridgeDocumentProviderError.documentNotFound(identifier: "window-123")
        let description = error.errorDescription!
        #expect(description.contains("window-123"))
    }
}
