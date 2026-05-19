import Foundation

public struct RuntimeRelationships: Hashable, Sendable, Codable {
    public let subclasses: [RuntimeObject]
    public let conformingTypes: [RuntimeObject]

    public init(subclasses: [RuntimeObject], conformingTypes: [RuntimeObject]) {
        self.subclasses = subclasses
        self.conformingTypes = conformingTypes
    }

    public static let empty = RuntimeRelationships(subclasses: [], conformingTypes: [])
}
