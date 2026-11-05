import Foundation
import RuntimeViewerCore

/// How an image's cross references are prepared ahead of the queries that will
/// read them.
public struct RuntimeCrossReferencePreparationOptions: Hashable, Codable, Sendable {
    /// The most bytes of prepared cross references the engine's process
    /// keeps; past it, the images queried least recently are dropped, and
    /// prepared again when a query needs them.
    public var residentByteLimit: Int
    /// As ``RuntimeCrossReferenceQueryOptions/maximumConcurrentScans``.
    public var maximumConcurrentScans: Int?
    /// Ahead of the preparations waiting: an image a document shows.
    public var isPrioritized: Bool
    /// Keep the image only if it fits in the room left, dropping nothing for
    /// it: Keep Cross References Ready filling the limit ahead of the queries
    /// (proposal `on-demand-corpora-and-cross-references`).
    /// ``RuntimeCrossReferencePreparation/isKept`` says how it went. A peer
    /// that predates it keeps the image as any other, dropping the images
    /// queried least recently.
    public var evictsNothing: Bool

    public init(residentByteLimit: Int, maximumConcurrentScans: Int? = nil, isPrioritized: Bool = false, evictsNothing: Bool = false) {
        self.residentByteLimit = residentByteLimit
        self.maximumConcurrentScans = maximumConcurrentScans
        self.isPrioritized = isPrioritized
        self.evictsNothing = evictsNothing
    }

    private enum CodingKeys: String, CodingKey {
        case residentByteLimit
        case maximumConcurrentScans
        case isPrioritized
        case evictsNothing
    }

    /// Written out so that options from a peer that predates `evictsNothing`
    /// still decode: the synthesized decoder throws `keyNotFound` for it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        residentByteLimit = try container.decode(Int.self, forKey: .residentByteLimit)
        maximumConcurrentScans = try container.decodeIfPresent(Int.self, forKey: .maximumConcurrentScans)
        isPrioritized = try container.decode(Bool.self, forKey: .isPrioritized)
        evictsNothing = try container.decodeIfPresent(Bool.self, forKey: .evictsNothing) ?? false
    }
}
