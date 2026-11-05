import Foundation
import Semantic

extension RuntimeInterfaceCorpusStore.ImageCorpus {
    /// The corpus of an image made of `entries`, the visibility conditions they
    /// repeat stored once, with a summary that counts those once — and the
    /// array of entries. Both ways a corpus comes into being — printed, and
    /// read from derived data — end here.
    init(
        sharingVisibilityConditionsOf entries: consuming [RuntimeInterfaceCorpusEntry],
        skippedCount: Int,
        transformer: Transformer.Configuration,
        lastSearchedAt: Date = Date()
    ) {
        var conditionPool = RuntimeInterfaceVisibilityConditionPool()
        for entryIndex in entries.indices {
            entries[entryIndex].shareVisibilityConditions(in: &conditionPool)
        }
        let byteCount = entries.reduce(entries.allocatedByteCount + conditionPool.byteCount) { total, entry in total + entry.byteCount }
        self.init(
            entries: entries,
            summary: RuntimeInterfaceCorpusBuildSummary(objectCount: entries.count, skippedCount: skippedCount, byteCount: byteCount),
            transformer: transformer,
            lastSearchedAt: lastSearchedAt
        )
    }
}
