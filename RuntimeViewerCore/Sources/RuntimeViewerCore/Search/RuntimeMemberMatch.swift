import Foundation

/// A member whose name matched a member search.
public struct RuntimeMemberMatch: Hashable, Codable, Sendable {
    public let object: RuntimeObject
    public let member: RuntimeMemberDeclaration
    /// Where the query matched inside `member.name`, for highlighting.
    public let matchRangeInName: RuntimeTextRange

    public init(object: RuntimeObject, member: RuntimeMemberDeclaration, matchRangeInName: RuntimeTextRange) {
        self.object = object
        self.member = member
        self.matchRangeInName = matchRangeInName
    }
}

extension RuntimeMemberMatch {
    /// What a member match carries besides its object.
    struct Hit: Codable, Sendable {
        let member: RuntimeMemberDeclaration
        let matchRangeInName: RuntimeTextRange
    }
}
