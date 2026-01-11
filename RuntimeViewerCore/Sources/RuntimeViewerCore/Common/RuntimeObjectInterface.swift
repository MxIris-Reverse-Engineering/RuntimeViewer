import Foundation
public import Semantic

public struct RuntimeObjectInterface: Codable, Sendable {
    public let object: RuntimeObject
    
    public let interfaceString: SemanticString
}
