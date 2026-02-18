#if canImport(RuntimeViewerMCPBridge)
import AppKit
import RuntimeViewerApplication
import RuntimeViewerMCPBridge
import RuntimeViewerMCPShared

@MainActor
final class AppMCPBridgeWindowProvider: MCPBridgeWindowProvider {
    func allWindowContexts() -> [MCPBridgeWindowContext] {
        NSDocumentController.shared.documents.compactMap { document -> MCPBridgeWindowContext? in
            guard let document = document as? Document else { return nil }
            guard let window = document.windowControllers.first?.window else { return nil }
            return MCPBridgeWindowContext(
                identifier: "\(window.windowNumber)",
                displayName: window.title,
                isKeyWindow: window.isKeyWindow,
                selectedRuntimeObject: document.documentState.selectedRuntimeObject,
                runtimeEngine: document.documentState.runtimeEngine
            )
        }
    }

    func windowContext(forIdentifier identifier: String) -> MCPBridgeWindowContext? {
        for document in NSDocumentController.shared.documents {
            guard let document = document as? Document else { continue }
            guard let window = document.windowControllers.first?.window else { continue }
            if identifier == "\(window.windowNumber)" {
                return MCPBridgeWindowContext(
                    identifier: identifier,
                    displayName: window.title,
                    isKeyWindow: window.isKeyWindow,
                    selectedRuntimeObject: document.documentState.selectedRuntimeObject,
                    runtimeEngine: document.documentState.runtimeEngine
                )
            }
        }
        return nil
    }
}
#endif
