import Foundation
import Semantic

/// Which parts of an interface a hit may land in. The mapping to
/// `RuntimeSemanticKind` is closed: `symbolsOnly` is exactly the kinds whose
/// `isSymbol` is true; `keyword`, `standard`, `numeric`, `error` and `other`
/// are matched by `all` and `excludeComments` alone.
public enum RuntimeInterfaceSearchScope: String, Codable, Hashable, Sendable, CaseIterable {
    case all
    case excludeComments
    case commentsOnly
    case symbolsOnly

    public func includes(_ kind: RuntimeSemanticKind) -> Bool {
        switch self {
        case .all: true
        case .excludeComments: kind != .comment
        case .commentsOnly: kind == .comment
        case .symbolsOnly: kind.isSymbol
        }
    }
}
