import Foundation
import RuntimeViewerCore
@testable import RuntimeViewerMCPBridge

final class MockMCPBridgeDocumentProvider: MCPBridgeDocumentProvider, @unchecked Sendable {
    var contexts: [MCPBridgeDocumentContext] = []

    func allDocumentContexts() async -> [MCPBridgeDocumentContext] {
        contexts
    }

    func documentContext(forIdentifier identifier: String) async throws -> MCPBridgeDocumentContext {
        guard let context = contexts.first(where: { $0.identifier == identifier }) else {
            throw MCPBridgeDocumentProviderError.documentNotFound(identifier: identifier)
        }
        return context
    }
}
