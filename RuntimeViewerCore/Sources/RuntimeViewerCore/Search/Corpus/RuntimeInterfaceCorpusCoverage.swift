import Foundation
import Semantic

/// The coverage the store reports: one state per image it knows about, plus
/// the resident budget.
public struct RuntimeInterfaceCorpusCoverage: Hashable, Codable, Sendable {
    public let statesByImagePath: [String: RuntimeInterfaceCorpusBuildState]
    /// What the corpora in memory take; a corpus held only by derived data
    /// counts for nothing.
    public let residentByteCount: Int
    public let residentByteLimit: Int
    /// The built images whose corpus was read from derived data rather than
    /// printed, each with what reading it took — every one is also `.built`
    /// in `statesByImagePath`, in memory or not. An entry goes when the image
    /// stops being built, or is printed again. A peer that keeps no derived
    /// data, or predates it, sends none.
    public let restoredImagesByImagePath: [String: RuntimeInterfaceCorpusRestoredImage]

    public init(
        statesByImagePath: [String: RuntimeInterfaceCorpusBuildState],
        residentByteCount: Int,
        residentByteLimit: Int,
        restoredImagesByImagePath: [String: RuntimeInterfaceCorpusRestoredImage] = [:]
    ) {
        self.statesByImagePath = statesByImagePath
        self.residentByteCount = residentByteCount
        self.residentByteLimit = residentByteLimit
        self.restoredImagesByImagePath = restoredImagesByImagePath
    }

    /// Written out so that a peer which predates `restoredImagesByImagePath`
    /// still decodes: the synthesized decoder throws `keyNotFound` for it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statesByImagePath = try container.decode([String: RuntimeInterfaceCorpusBuildState].self, forKey: .statesByImagePath)
        residentByteCount = try container.decode(Int.self, forKey: .residentByteCount)
        residentByteLimit = try container.decode(Int.self, forKey: .residentByteLimit)
        restoredImagesByImagePath = try container.decodeIfPresent([String: RuntimeInterfaceCorpusRestoredImage].self, forKey: .restoredImagesByImagePath) ?? [:]
    }

    public static let empty = RuntimeInterfaceCorpusCoverage(statesByImagePath: [:], residentByteCount: 0, residentByteLimit: 0)
}
