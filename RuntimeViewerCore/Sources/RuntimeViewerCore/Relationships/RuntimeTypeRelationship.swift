import Foundation

/// The three relationship views of the Find navigator, with Xcode's
/// semantics:
///
/// - `ancestors` — a class's whole superclass chain, the protocols each level
///   adopts, and the protocols those refine; a protocol's refined protocols;
///   a struct's or enum's adopted protocols.
/// - `descendants` — every transitive subclass of a class, nested by level;
///   every protocol refining a protocol, recursively.
/// - `conformers` — the types adopting a protocol directly, the same set the
///   Inspector's Relationships tab shows.
public enum RuntimeTypeRelationship: String, Codable, Hashable, Sendable, CaseIterable {
    case ancestors
    case descendants
    case conformers
}
