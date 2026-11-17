import Testing
import Foundation
import RuntimeViewerCore
@testable import RuntimeViewerMCPBridge

/// Whether an image's objects are loaded is a question about one engine, and
/// two windows can be on two engines. The bridge used to remember the image
/// paths it had loaded objects for across every window, so loading an image's
/// objects in one window made every other window report them loaded. The
/// codebase audit's CA.14.
@Suite("MCP objects loaded per engine", .serialized)
struct MCPObjectsLoadedPerEngineTests {
    private static let imagePath = "/usr/lib/libobjc.A.dylib"

    private static func context(_ identifier: String, on engine: RuntimeEngine) -> MCPBridgeDocumentContext {
        MCPBridgeDocumentContext(
            identifier: identifier,
            displayName: identifier,
            isKeyWindow: false,
            selectedRuntimeObject: nil,
            selectedImageNode: nil,
            runtimeEngine: engine
        )
    }

    @Test("Loading an image's objects in one window's engine leaves another window's engine reported not loaded")
    func objectsLoadedIsAnsweredPerEngine() async throws {
        let firstEngine = RuntimeEngine(source: .local, engineID: "MCPObjectsLoadedPerEngineTests.first")
        let secondEngine = RuntimeEngine(source: .local, engineID: "MCPObjectsLoadedPerEngineTests.second")
        try await firstEngine.connect()
        try await secondEngine.connect()
        let provider = MockMCPBridgeDocumentProvider()
        provider.contexts = [Self.context("first", on: firstEngine), Self.context("second", on: secondEngine)]
        let server = MCPBridgeServer(documentProvider: provider)

        _ = try await server.loadObjects(windowIdentifier: "first", imagePath: Self.imagePath)

        let firstResponse = try await server.isObjectsLoaded(windowIdentifier: "first", imagePath: Self.imagePath)
        let secondResponse = try await server.isObjectsLoaded(windowIdentifier: "second", imagePath: Self.imagePath)
        #expect(firstResponse.isLoaded)
        #expect(!secondResponse.isLoaded, "The second window's engine has not loaded the image's objects.")
    }
}
