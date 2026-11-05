import Foundation
import Semantic

/// How the query text is matched against interface text — Xcode's four text
/// match styles plus regular expressions.
public enum RuntimeInterfaceSearchMatchMode: String, Codable, Hashable, Sendable, CaseIterable {
    case containing
    case matchingWord
    case startingWith
    case endingWith
    case regularExpression
}
