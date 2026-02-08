#if canImport(RuntimeViewerMCPBridge)
import AppKit
import RuntimeViewerApplication
import RuntimeViewerMCPBridge
import RuntimeViewerMCPShared

final class AppMCPBridgeWindowProvider: MCPBridgeWindowProvider, @unchecked Sendable {
    @MainActor
    func allWindowContexts() -> [MCPBridgeWindowContext] {
        NSDocumentController.shared.documents.compactMap { document -> MCPBridgeWindowContext? in
            guard let document = document as? Document else { return nil }
            guard let window = document.windowControllers.first?.window else { return nil }
            return MCPBridgeWindowContext(
                identifier: "\(window.windowNumber)",
                displayName: window.title,
                isKeyWindow: window.isKeyWindow,
                appState: document.appState
            )
        }
    }

    @MainActor
    func windowContext(forIdentifier identifier: String) -> MCPBridgeWindowContext? {
        for document in NSDocumentController.shared.documents {
            guard let document = document as? Document else { continue }
            guard let window = document.windowControllers.first?.window else { continue }
            if "\(window.windowNumber)" == identifier {
                return MCPBridgeWindowContext(
                    identifier: identifier,
                    displayName: window.title,
                    isKeyWindow: window.isKeyWindow,
                    appState: document.appState
                )
            }
        }
        return nil
    }
}
#endif
