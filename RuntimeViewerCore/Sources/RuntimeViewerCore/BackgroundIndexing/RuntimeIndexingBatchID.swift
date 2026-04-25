public import Foundation

public struct RuntimeIndexingBatchID: Hashable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}
