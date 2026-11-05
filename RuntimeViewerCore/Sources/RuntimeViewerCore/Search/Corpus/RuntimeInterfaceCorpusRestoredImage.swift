import Foundation
import Semantic

/// One image whose corpus came from derived data rather than from the
/// printer.
public struct RuntimeInterfaceCorpusRestoredImage: Hashable, Codable, Sendable {
    public var summary: RuntimeInterfaceCorpusBuildSummary
    /// Seconds from the read's start to the corpus being in the store:
    /// waiting for a turn to read, the file, its checks and the walk through
    /// what was read. Only the summary is read for a corpus that does not
    /// fit in the room left, so its duration is that read's.
    public var duration: Double

    public init(summary: RuntimeInterfaceCorpusBuildSummary, duration: Double) {
        self.summary = summary
        self.duration = duration
    }
}
