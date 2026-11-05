import Foundation
import Semantic

/// A member a line of an interface declares, as the line spells it: what the
/// content pane offers Find Call Hierarchy and the other cross-reference
/// commands for. Read off the line alone, so it says no more than the line
/// does: a Swift field and variable read alike and come back as a variable,
/// and an initializer is never static.
public struct RuntimeDeclaredMember: Hashable, Sendable {
    /// As `RuntimeMemberDeclaration.name` spells it: a whole selector, a Swift
    /// function's base name, `init`, `subscript`.
    public let name: String
    public let kind: RuntimeMemberKind
    public let isStatic: Bool

    public init(name: String, kind: RuntimeMemberKind, isStatic: Bool) {
        self.name = name
        self.kind = kind
        self.isStatic = isStatic
    }
}
