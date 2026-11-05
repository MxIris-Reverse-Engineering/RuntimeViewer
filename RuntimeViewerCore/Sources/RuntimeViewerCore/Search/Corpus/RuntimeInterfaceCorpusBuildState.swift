import Foundation
import Semantic

/// Where one image's corpus stands.
///
/// `built` means searchable: its corpus in memory, or held by the serving
/// process's derived data, which a search reads back.
///
/// There is no "unbuilt" case: an image absent from the coverage map is one
/// the store holds nothing for — never asked for, evicted, or cancelled
/// before it finished. Cancellation deliberately leaves no `failed` behind;
/// a build that threw does, and stays there until something asks for that
/// image again.
public enum RuntimeInterfaceCorpusBuildState: Hashable, Codable, Sendable {
    case pending
    case building(RuntimeInterfaceCorpusBuildProgress)
    case built(RuntimeInterfaceCorpusBuildSummary)
    case failed(message: String)

    public var isBuilt: Bool {
        if case .built = self { return true }
        return false
    }

    /// Waiting for its turn or being printed.
    public var isActive: Bool {
        switch self {
        case .pending, .building: true
        case .built, .failed: false
        }
    }
}
