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
        // Xcode's spelling, the `displayName` IDEFoundation declares.
        case .descendantTypes: "Descendent Types"
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

    /// Whether the third path component offers the text match styles: Text
    /// and the relationship modes, the queries Xcode declares
    /// `supportsAnchoring` for. Regular Expression is a pattern of its own and
    /// offers none, in Xcode too.
    public var hasTextMatchStyles: Bool { self == .text || relationship != nil }

    /// Whether the third path component offers the member match styles, and
    /// the scope row the member kinds.
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

/// The third path component in text and relationship modes: Xcode's four
/// match styles. One choice serves all of those modes, as Xcode keeps one
/// anchoring for every query: Matching Word picked in Text mode is still
/// picked in Ancestor Types.
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

/// The third path component in member mode: the text match styles, matched
/// against member names under the text search's rules, plus a regular
/// expression — which text mode offers as a mode of its own, as Xcode does.
public enum FindMemberMatchStyle: String, CaseIterable, Hashable, Sendable {
    case containing
    case matchingWord
    case startingWith
    case endingWith
    case regularExpression

    public var title: String {
        switch self {
        case .containing: FindTextMatchStyle.containing.title
        case .matchingWord: FindTextMatchStyle.matchingWord.title
        case .startingWith: FindTextMatchStyle.startingWith.title
        case .endingWith: FindTextMatchStyle.endingWith.title
        case .regularExpression: FindMode.regularExpression.title
        }
    }

    public var matchMode: RuntimeInterfaceSearchMatchMode {
        switch self {
        case .containing: .containing
        case .matchingWord: .matchingWord
        case .startingWith: .startingWith
        case .endingWith: .endingWith
        case .regularExpression: .regularExpression
        }
    }
}

/// The member kinds, offered in the scope row while the mode is Members.
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

/// The images a search reads — the scope row's button.
public enum FindScope: Hashable, Sendable {
    /// Every indexed image.
    case allIndexedImages
    /// The image the sidebar lists, `DocumentState.currentImageNode`, as it
    /// is when the search runs.
    case currentImage
    /// The images picked in the scope chooser, or the ones the results on
    /// screen came from; never empty.
    case images(Set<String>)

    /// `Indexed Images`, `Current Image`, `Foundation`, `3 Images`: the scope
    /// as the scope menu names it and as the scope button's title says it
    /// after `In`. Xcode takes both from one
    /// `+[IDEBatchFindNamedScope titleForNamedScope:inWorkspace:]`.
    public var name: String {
        switch self {
        case .allIndexedImages:
            "Indexed Images"
        case .currentImage:
            "Current Image"
        case .images(let imagePaths):
            if imagePaths.count == 1, let imagePath = imagePaths.first {
                Self.imageName(of: imagePath)
            } else {
                "\(imagePaths.count) Images"
            }
        }
    }

    /// `In Indexed Images`, `In Current Image`, `In Foundation`, `In 3 Images`.
    public var title: String { "In \(name)" }

    /// Whether the scope button draws its title in the accent colour: every
    /// scope but the default one, as
    /// `-[IDEFindNavigatorQueryParametersController refreshUserInterface:]`
    /// accents every scope but the workspace.
    public var isAccented: Bool { self != .allIndexedImages }

    /// An image's name wherever the navigators show one — Find's scope, result rows and summary
    /// bar, and the Report navigator's rows: its file name, extension included.
    public static func imageName(of imagePath: String) -> String {
        (imagePath as NSString).lastPathComponent
    }
}

/// Everything the navigator sends to the engine for one search.
public struct FindQuery: Hashable, Sendable {
    public var mode: FindMode = .text
    public var text: String = ""
    /// The match style of Text and the relationship modes, one for all of them.
    public var textMatchStyle: FindTextMatchStyle = .containing
    /// Kept apart from `textMatchStyle`: it can be a regular expression,
    /// which text mode reaches through a mode of its own.
    public var memberMatchStyle: FindMemberMatchStyle = .containing
    public var memberKindFilter: FindMemberKindFilter = .any
    public var isCaseSensitive: Bool = false
    public var scope: FindScope = .allIndexedImages

    public init(
        mode: FindMode = .text,
        text: String = "",
        textMatchStyle: FindTextMatchStyle = .containing,
        memberMatchStyle: FindMemberMatchStyle = .containing,
        memberKindFilter: FindMemberKindFilter = .any,
        isCaseSensitive: Bool = false,
        scope: FindScope = .allIndexedImages
    ) {
        self.mode = mode
        self.text = text
        self.textMatchStyle = textMatchStyle
        self.memberMatchStyle = memberMatchStyle
        self.memberKindFilter = memberKindFilter
        self.isCaseSensitive = isCaseSensitive
        self.scope = scope
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { trimmedText.isEmpty }
}
