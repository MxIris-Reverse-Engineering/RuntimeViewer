import Foundation
import RuntimeViewerCore

public enum RuntimeCrossReferenceKind: String, Hashable, Codable, Sendable {
    case call
    case tailCall
    case messageSend
    case superMessageSend
    case typeReference
    case indirectCall
}
