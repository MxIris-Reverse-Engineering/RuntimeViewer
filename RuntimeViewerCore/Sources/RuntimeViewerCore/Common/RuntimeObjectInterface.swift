import Foundation
public import Semantic

public struct RuntimeObjectInterface: Codable, Sendable {
    public let object: RuntimeObject

    public let interfaceString: SemanticString

    public let impMappings: [RuntimeIMPMapping]

    public init(object: RuntimeObject, interfaceString: SemanticString, impMappings: [RuntimeIMPMapping] = []) {
        self.object = object
        self.interfaceString = interfaceString
        self.impMappings = impMappings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = try container.decode(RuntimeObject.self, forKey: .object)
        interfaceString = try container.decode(SemanticString.self, forKey: .interfaceString)
        impMappings = try container.decodeIfPresent([RuntimeIMPMapping].self, forKey: .impMappings) ?? []
    }
}
