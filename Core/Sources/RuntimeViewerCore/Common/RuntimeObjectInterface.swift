import Foundation
public import Semantic

public struct RuntimeObjectInterface: Codable, Sendable {
    public let name: RuntimeObjectName
    
    public let interfaceString: SemanticString
}
