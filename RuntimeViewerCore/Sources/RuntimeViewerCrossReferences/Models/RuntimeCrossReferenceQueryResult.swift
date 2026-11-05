import Foundation
import RuntimeViewerCore

public struct RuntimeCrossReferenceQueryResult: Hashable, Codable, Sendable {
    /// Callers in image order, then by instruction address; callees in
    /// instruction order.
    public let references: [RuntimeCrossReference]
    /// `false` when ``RuntimeCrossReferenceQueryOptions/resultLimit`` cut the
    /// query short.
    public let isComplete: Bool

    public init(references: [RuntimeCrossReference], isComplete: Bool) {
        self.references = references
        self.isComplete = isComplete
    }
}
