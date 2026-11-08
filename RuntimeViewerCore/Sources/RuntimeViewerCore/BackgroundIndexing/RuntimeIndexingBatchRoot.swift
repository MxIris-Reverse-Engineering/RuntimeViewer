import Foundation

/// One image a batch starts its walk from, with how many levels of its
/// dependencies the walk follows below it.
///
/// A batch of several roots is what an engine that borrows shared cache
/// images hands to their owner: the borrowed images its own walk reached,
/// each with the depth the walk still had to go below it.
public struct RuntimeIndexingBatchRoot: Sendable, Hashable {
    public let imagePath: String

    public let depth: Int

    public init(imagePath: String, depth: Int) {
        self.imagePath = imagePath
        self.depth = depth
    }
}
