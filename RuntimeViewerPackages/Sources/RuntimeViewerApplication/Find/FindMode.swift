import Foundation
import RuntimeViewerCore

/// What the Find navigator looks for — the second component of its mode
/// path (`Find ▸ Text ▸ Containing`), in the order Xcode lists its own.
public enum FindMode: String, CaseIterable, Hashable, Sendable {
    case text
    case regularExpression
    case ancestorTypes
    case descendantTypes
    case conformingTypes
    case members

    public var title: String {
        switch self {
        case .text: "Text"
        case .regularExpression: "Regular Expression"
        case .ancestorTypes: "Ancestor Types"
        case .descendantTypes: "Descendant Types"
        case .conformingTypes: "Conforming Types"
        case .members: "Members"
        }
    }

    /// The search field's placeholder, named after what is typed there.
    public var searchFieldPlaceholder: String {
        switch self {
        case .text: "Text"
        case .regularExpression: "Regular Expression"
        case .ancestorTypes, .descendantTypes, .conformingTypes: "Type Name"
        case .members: "Member Name"
        }
    }

    /// Whether the third path component offers the text match styles.
    public var hasTextMatchStyles: Bool { self == .text }

    /// Whether the third path component offers the member kinds.
    public var hasMemberKinds: Bool { self == .members }

    /// The relationship a relationship mode walks; `nil` for the others.
    public var relationship: RuntimeTypeRelationship? {
        switch self {
        case .ancestorTypes: .ancestors
        case .descendantTypes: .descendants
        case .conformingTypes: .conformers
        case .text, .regularExpression, .members: nil
        }
    }

    /// Whether results come out of the interface corpus (and so depend on it
    /// being built) rather than out of the relationship tables.
    public var readsCorpus: Bool {
        switch self {
        case .text, .regularExpression, .members: true
        case .ancestorTypes, .descendantTypes, .conformingTypes: false
        }
    }
}

/// The third path component in text mode: Xcode's four match styles.
public enum FindTextMatchStyle: String, CaseIterable, Hashable, Sendable {
    case containing
    case matchingWord
    case startingWith
    case endingWith

    public var title: String {
        switch self {
        case .containing: "Containing"
        case .matchingWord: "Matching Word"
        case .startingWith: "Starting With"
        case .endingWith: "Ending With"
        }
    }

    public var matchMode: RuntimeInterfaceSearchMatchMode {
        switch self {
        case .containing: .containing
        case .matchingWord: .matchingWord
        case .startingWith: .startingWith
        case .endingWith: .endingWith
        }
    }
}

/// The third path component in member mode: one member kind, or any.
public enum FindMemberKindFilter: Hashable, Sendable {
    case any
    case kind(RuntimeMemberKind)

    public static let allCases: [FindMemberKindFilter] = [.any] + RuntimeMemberKind.allCases.map(FindMemberKindFilter.kind)

    public var title: String {
        switch self {
        case .any: "Any Member"
        case .kind(let kind): kind.displayName
        }
    }

    /// The kind set a `RuntimeMemberSearchQuery` takes: `nil` for any.
    public var kinds: Set<RuntimeMemberKind>? {
        switch self {
        case .any: nil
        case .kind(let kind): [kind]
        }
    }
}

/// Everything the navigator sends to the engine for one search.
public struct FindQuery: Hashable, Sendable {
    public var mode: FindMode = .text
    public var text: String = ""
    public var textMatchStyle: FindTextMatchStyle = .containing
    public var memberKindFilter: FindMemberKindFilter = .any
    public var isCaseSensitive: Bool = false

    public init(
        mode: FindMode = .text,
        text: String = "",
        textMatchStyle: FindTextMatchStyle = .containing,
        memberKindFilter: FindMemberKindFilter = .any,
        isCaseSensitive: Bool = false
    ) {
        self.mode = mode
        self.text = text
        self.textMatchStyle = textMatchStyle
        self.memberKindFilter = memberKindFilter
        self.isCaseSensitive = isCaseSensitive
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { trimmedText.isEmpty }
}
