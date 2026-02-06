#if canImport(RuntimeViewerMCPService)
import Foundation
import AppKit
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerMCPService

final class AppMCPBridgeDelegate: MCPBridgeDelegate, @unchecked Sendable {
    func selectedRuntimeObject() async -> RuntimeObject? {
        await MainActor.run {
            guard let document = NSDocumentController.shared.currentDocument as? Document else {
                return nil
            }
            return document.appServices.selectedRuntimeObject
        }
    }

    func runtimeEngine() async -> RuntimeEngine {
        await MainActor.run {
            guard let document = NSDocumentController.shared.currentDocument as? Document else {
                return .shared
            }
            return document.appServices.runtimeEngine
        }
    }

    func generationOptions() async -> RuntimeObjectInterface.GenerationOptions {
        .init()
    }
}
#endif
