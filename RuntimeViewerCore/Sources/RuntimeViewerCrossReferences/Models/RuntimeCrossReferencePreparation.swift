import Foundation
import RuntimeViewerCore

/// An image's prepared cross references.
public struct RuntimeCrossReferencePreparation: Hashable, Codable, Sendable {
    /// The references kept: the calls, sends, imported names and type
    /// references a query reads.
    public let referenceCount: Int
    /// The memory they hold, with the names read for them.
    public let byteCount: Int
    /// Whether the engine's process keeps them. Not for an image larger than
    /// the limit, nor for one prepared with
    /// ``RuntimeCrossReferencePreparationOptions/evictsNothing`` that did not
    /// fit in the room left; a query prepares it again when it needs it. A
    /// peer that predates it says nothing, which reads as kept.
    public let isKept: Bool

    public init(referenceCount: Int, byteCount: Int, isKept: Bool = true) {
        self.referenceCount = referenceCount
        self.byteCount = byteCount
        self.isKept = isKept
    }

    private enum CodingKeys: String, CodingKey {
        case referenceCount
        case byteCount
        case isKept
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        referenceCount = try container.decode(Int.self, forKey: .referenceCount)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        isKept = try container.decodeIfPresent(Bool.self, forKey: .isKept) ?? true
    }
}
