import Foundation

/// A base of a C++ class, as far as following it needs: its name, the
/// mangling its typeinfo goes by, and whether the class's own image defines
/// it.
struct RuntimeCPlusPlusBaseReference: Hashable, Sendable {
    var qualifiedName: String
    var mangledTypeName: String
    var isInSameImage: Bool
}
