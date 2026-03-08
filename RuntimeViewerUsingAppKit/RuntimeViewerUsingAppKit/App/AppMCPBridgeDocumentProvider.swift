import AppKit
import RuntimeViewerApplication
import RuntimeViewerMCPBridge

final class AppMCPBridgeDocumentProvider: MCPBridgeDocumentProvider {
    func allDocumentContexts() async -> [MCPBridgeDocumentContext] {
        await MainActor.run {
            NSDocumentController.shared.documents.compactMap { document -> MCPBridgeDocumentContext? in
                guard let document = document as? Document else { return nil }
                guard let window = document.windowControllers.first?.window else { return nil }
                return makeContext(from: document, window: window)
            }
        }
    }

    func documentContext(forIdentifier identifier: String) async throws -> MCPBridgeDocumentContext {
        try await MainActor.run {
            for document in NSDocumentController.shared.documents {
                guard let document = document as? Document else { continue }
                guard let window = document.windowControllers.first?.window else { continue }
                if identifier == document.mcpIdentifier {
                    return makeContext(from: document, window: window)
                }
            }
            throw MCPBridgeDocumentProviderError.documentNotFound(identifier: identifier)
        }
    }

    @MainActor
    private func makeContext(from document: Document, window: NSWindow) -> MCPBridgeDocumentContext {
        MCPBridgeDocumentContext(
            identifier: document.mcpIdentifier,
            displayName: window.title,
            isKeyWindow: window.isKeyWindow,
            selectedRuntimeObject: document.documentState.selectedRuntimeObject,
            selectedImageNode: document.documentState.currentImageNode,
            runtimeEngine: document.documentState.runtimeEngine
        )
    }
}
