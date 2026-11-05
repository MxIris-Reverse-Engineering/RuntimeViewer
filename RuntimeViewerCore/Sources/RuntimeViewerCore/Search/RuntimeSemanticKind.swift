import Foundation
public import Semantic

/// `Semantic.SemanticType` flattened to a `Codable` enum that crosses the
/// engine boundary. The type's own `TypeKind` / `Context` payloads are folded
/// away: a search result needs to know that a hit sits in a type name or a
/// comment, not whether the type is a struct or a class.
public enum RuntimeSemanticKind: String, Codable, Hashable, Sendable, CaseIterable {
    case standard
    case comment
    case keyword
    case variable
    case numeric
    case argument
    case error
    case type
    case member
    case function
    case other

    public init(_ semanticType: SemanticType) {
        switch semanticType {
        case .standard: self = .standard
        case .comment: self = .comment
        case .keyword: self = .keyword
        case .variable: self = .variable
        case .numeric: self = .numeric
        case .argument: self = .argument
        case .error: self = .error
        case .type: self = .type
        case .member: self = .member
        case .function: self = .function
        case .other: self = .other
        }
    }

    /// Identifier-like kinds — what "symbols only" means.
    public var isSymbol: Bool {
        switch self {
        case .type, .member, .function, .variable, .argument: true
        case .standard, .comment, .keyword, .numeric, .error, .other: false
        }
    }
}
