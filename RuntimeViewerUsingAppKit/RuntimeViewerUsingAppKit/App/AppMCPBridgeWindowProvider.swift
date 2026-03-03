#if canImport(RuntimeViewerMCPBridge)
import AppKit
import RuntimeViewerApplication
import RuntimeViewerMCPBridge

final class AppMCPBridgeWindowProvider: MCPBridgeWindowProvider {
    func allWindowContexts() async -> [MCPBridgeWindowContext] {
        await MainActor.run {
            NSDocumentController.shared.documents.compactMap { document -> MCPBridgeWindowContext? in
                guard let document = document as? Document else { return nil }
                guard let window = document.windowControllers.first?.window else { return nil }
                return makeContext(from: document, window: window)
            }
        }
    }

    func windowContext(forIdentifier identifier: String) async -> MCPBridgeWindowContext? {
        await MainActor.run {
            for document in NSDocumentController.shared.documents {
                guard let document = document as? Document else { continue }
                guard let window = document.windowControllers.first?.window else { continue }
                if identifier == "\(window.windowNumber)" {
                    return makeContext(from: document, window: window)
                }
            }
            return nil
        }
    }

    @MainActor
    private func makeContext(from document: Document, window: NSWindow) -> MCPBridgeWindowContext {
        MCPBridgeWindowContext(
            identifier: "\(window.windowNumber)",
            displayName: window.title,
            isKeyWindow: window.isKeyWindow,
            selectedRuntimeObject: document.documentState.selectedRuntimeObject,
            selectedImageNode: document.documentState.currentImageNode,
            runtimeEngine: document.documentState.runtimeEngine
        )
    }
}
#endif
