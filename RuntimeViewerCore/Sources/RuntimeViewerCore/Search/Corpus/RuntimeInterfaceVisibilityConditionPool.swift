import Foundation
import Semantic

/// One stored copy of every distinct visibility condition, and of every
/// distinct list of them, for the entries of one corpus to share.
///
/// Every entry's `VisibilityRegionTable` comes with a list of conditions of
/// its own, and every condition with arrays of requirements of its own. But
/// the conditions are combinations of a couple of dozen Generation Options, so
/// the tens of thousands of entries of an image repeat the same few: kept
/// apart, they took about 30 MB of an engine indexing UIKitCore, AppKit and
/// six other frameworks (proposal `engine-resident-memory`). An entry that
/// takes its table back through `sharedTable(for:)` holds the stored copies,
/// and the ones it came with are freed.
struct RuntimeInterfaceVisibilityConditionPool {
    private var conditionLists: Set<[VisibilityCondition]> = []

    private var conditions: Set<VisibilityCondition> = []

    /// What the stored copies allocate, counted once however many entries
    /// share them.
    private(set) var byteCount = 0

    /// `table` with its conditions swapped for the stored copies, stored now
    /// if they are new.
    mutating func sharedTable(for table: VisibilityRegionTable) -> VisibilityRegionTable {
        guard !table.conditions.isEmpty else { return table }
        if let storedIndex = conditionLists.firstIndex(of: table.conditions) {
            return VisibilityRegionTable(regions: table.regions, conditions: conditionLists[storedIndex])
        }
        var sharedConditions: [VisibilityCondition] = []
        sharedConditions.reserveCapacity(table.conditions.count)
        for condition in table.conditions {
            sharedConditions.append(sharedCondition(condition))
        }
        conditionLists.insert(sharedConditions)
        byteCount += sharedConditions.allocatedByteCount
        return VisibilityRegionTable(regions: table.regions, conditions: sharedConditions)
    }

    private mutating func sharedCondition(_ condition: VisibilityCondition) -> VisibilityCondition {
        let (isNew, storedCondition) = conditions.insert(condition)
        if isNew {
            byteCount += Self.allocatedByteCount(of: storedCondition)
        }
        return storedCondition
    }

    /// The condition's arrays of alternatives and of requirements, and the
    /// option names too long to be kept inline.
    private static func allocatedByteCount(of condition: VisibilityCondition) -> Int {
        condition.alternatives.reduce(condition.alternatives.allocatedByteCount) { total, alternative in
            alternative.reduce(total + alternative.allocatedByteCount) { subtotal, requirement in
                subtotal + requirement.option.allocatedByteCount
            }
        }
    }
}

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
