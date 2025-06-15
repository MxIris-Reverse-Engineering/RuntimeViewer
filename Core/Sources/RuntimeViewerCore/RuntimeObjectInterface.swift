import Foundation
import Semantic

public struct RuntimeObjectInterface: Codable {
    public let name: RuntimeObjectName
    public let interfaceString: SemanticString
}
