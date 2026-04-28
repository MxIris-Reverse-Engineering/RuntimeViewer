import RuntimeViewerCore
import RxAppKit

enum BackgroundIndexingNode: Hashable {
    case batch(RuntimeIndexingBatch, items: [BackgroundIndexingNode])
    case item(batchID: RuntimeIndexingBatchID, item: RuntimeIndexingTaskItem)
}

extension BackgroundIndexingNode: OutlineNodeType {
    var children: [BackgroundIndexingNode] {
        switch self {
        case .batch(_, let items): return items
        case .item: return []
        }
    }
}

extension BackgroundIndexingNode: Differentiable {
    enum Identifier: Hashable {
        case batch(RuntimeIndexingBatchID)
        case item(batchID: RuntimeIndexingBatchID, itemID: String)
    }

    var differenceIdentifier: Identifier {
        switch self {
        case .batch(let batch, _):
            return .batch(batch.id)
        case .item(let batchID, let item):
            return .item(batchID: batchID, itemID: item.id)
        }
    }
}
