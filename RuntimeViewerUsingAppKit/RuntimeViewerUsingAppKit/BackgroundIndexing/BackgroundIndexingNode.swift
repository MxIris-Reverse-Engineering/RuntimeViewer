import RuntimeViewerCore
import RxAppKit

enum BackgroundIndexingNode: Hashable {
    case section(SectionKind, batches: [BackgroundIndexingNode])
    case batch(RuntimeIndexingBatch, items: [BackgroundIndexingNode])
    case item(batchID: RuntimeIndexingBatchID, item: RuntimeIndexingTaskItem)

    enum SectionKind: Hashable {
        case active
        case history
    }
}

extension BackgroundIndexingNode: OutlineNodeType {
    var children: [BackgroundIndexingNode] {
        switch self {
        case .section(_, let batches): return batches
        case .batch(_, let items): return items
        case .item: return []
        }
    }
}

extension BackgroundIndexingNode: Differentiable {
    enum Identifier: Hashable {
        case section(SectionKind)
        case batch(RuntimeIndexingBatchID)
        case item(batchID: RuntimeIndexingBatchID, itemID: String)
    }

    // Identifier for `.section` is intentionally kind-only — not derived
    // from children. RxAppKit's staged changeset detects child insertions
    // and removals as nested diffs without recreating the section row,
    // which preserves the user's expand / collapse state across updates.
    var differenceIdentifier: Identifier {
        switch self {
        case .section(let kind, _):
            return .section(kind)
        case .batch(let batch, _):
            return .batch(batch.id)
        case .item(let batchID, let item):
            return .item(batchID: batchID, itemID: item.id)
        }
    }
}
