import Foundation
import RuntimeViewerCore

public protocol MCPBridgeDelegate: AnyObject, Sendable {
    func selectedRuntimeObject() async -> RuntimeObject?
    func runtimeEngine() async -> RuntimeEngine
    func generationOptions() async -> RuntimeObjectInterface.GenerationOptions
}
