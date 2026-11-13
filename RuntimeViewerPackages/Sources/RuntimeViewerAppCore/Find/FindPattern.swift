import Foundation

/// A pattern token in the Find navigator's query field — Digits, Any Word Characters and the rest — as data: the
/// regular expression it stands for and how the field shows it.
///
/// The query field is AppKitPlus's `NSFindPatternSearchField`, which holds AppKitPlus's `NSFindPattern`;
/// RuntimeViewerAppUI turns one into the other, property for property. Two patterns are equal when every property is
/// equal, `identifier` included: tokens with the same identifier are one token, the first a capture group and every
/// later one a backreference to it (`FindQueryTerm.regularExpressionPattern(escapingText:)`).
public struct FindPattern: Hashable, Sendable {
    /// The ICU regular expression the token stands for, a fragment of the term's expression.
    public var regularExpression: String

    /// The pattern's name in the field's pattern menu, such as "Digits".
    public var title: String

    /// The text drawn in the token, such as "#".
    public var tokenTitle: String

    /// Whether the token is a capture group that later tokens with its identifier refer back to. `false` for a
    /// pattern that matches nothing worth repeating, such as Word Break.
    public var allowsBackreferences: Bool

    /// What the token stands for in a replacement template — a tab for Tab — or `nil` for the text it matched.
    public var replacementString: String?

    /// Whether the pattern matches what something else does not, such as Non-ASCII Characters.
    public var isNegation: Bool

    /// Which token this is, or `nil` for a pattern definition. The query field gives every token it inserts an
    /// identifier of its own, a UUID string.
    public var identifier: String?

    public init(
        regularExpression: String,
        title: String,
        tokenTitle: String,
        allowsBackreferences: Bool = true,
        replacementString: String? = nil,
        isNegation: Bool = false,
        identifier: String? = nil
    ) {
        self.regularExpression = regularExpression
        self.title = title
        self.tokenTitle = tokenTitle
        self.allowsBackreferences = allowsBackreferences
        self.replacementString = replacementString
        self.isNegation = isNegation
        self.identifier = identifier
    }
}

// MARK: - Property list

extension FindPattern {
    /// The keys of a pattern's property-list dictionary: those Xcode's find field writes to the pasteboard, which
    /// AppKitPlus reads and writes too (`NSFindPattern.m`).
    private enum PropertyListKey {
        static let regularExpression = "NSFindPatternRegularExpressionKey"
        static let title = "NSFindPatternDisplayStringKey"
        static let tokenTitle = "NSFindPatternTokenStringKey"
        static let replacementString = "NSFindPatternTokenReplacementStringKey"
        static let allowsBackreferences = "NSFindPatternTokenAllowsBackreferencesKey"
        static let isNegation = "NSFindPatternTokenIsNegationKey"
        static let identifier = "NSFindPatternTokenUniqueIDKey"
    }

    /// The pattern as a property-list dictionary, as `-[NSFindPattern _propertyListRepresentation]` writes one: every
    /// property, the replacement string and the identifier only when there is one.
    var propertyListRepresentation: [String: Any] {
        var propertyList: [String: Any] = [
            PropertyListKey.regularExpression: regularExpression,
            PropertyListKey.title: title,
            PropertyListKey.tokenTitle: tokenTitle,
            PropertyListKey.allowsBackreferences: allowsBackreferences,
            PropertyListKey.isNegation: isNegation,
        ]
        if let replacementString {
            propertyList[PropertyListKey.replacementString] = replacementString
        }
        if let identifier {
            propertyList[PropertyListKey.identifier] = identifier
        }
        return propertyList
    }

    /// A pattern from a property-list dictionary, as `+[NSFindPattern _patternWithPropertyListRepresentation:]` reads
    /// one: `nil` without a string regular expression; a missing title reads as empty, a missing token title as the
    /// title, a missing flag as `false`, and a value of another type as a missing one. Other keys — the group numbers
    /// Xcode's field writes — are ignored.
    init?(propertyListRepresentation propertyList: [String: Any]) {
        guard let regularExpression = propertyList[PropertyListKey.regularExpression] as? String else { return nil }
        let title = propertyList[PropertyListKey.title] as? String ?? ""
        self.init(
            regularExpression: regularExpression,
            title: title,
            tokenTitle: propertyList[PropertyListKey.tokenTitle] as? String ?? title,
            allowsBackreferences: (propertyList[PropertyListKey.allowsBackreferences] as? NSNumber)?.boolValue ?? false,
            replacementString: propertyList[PropertyListKey.replacementString] as? String,
            isNegation: (propertyList[PropertyListKey.isNegation] as? NSNumber)?.boolValue ?? false,
            identifier: propertyList[PropertyListKey.identifier] as? String
        )
    }
}
