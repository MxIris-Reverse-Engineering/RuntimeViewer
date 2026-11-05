import Foundation
import Semantic

/// Progress of one image's corpus build: objects printed so far out of the
/// image's total. A named struct rather than a tuple because
/// `RuntimeEngineProgressCommand.Progress` has to be `Codable`.
public struct RuntimeInterfaceCorpusBuildProgress: Hashable, Codable, Sendable {
    public let built: Int
    public let total: Int

    public init(built: Int, total: Int) {
        self.built = built
        self.total = total
    }
}
