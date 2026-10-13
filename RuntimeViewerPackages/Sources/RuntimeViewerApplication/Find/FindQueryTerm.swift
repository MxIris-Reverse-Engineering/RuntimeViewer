import Foundation
import RuntimeViewerCore
#if canImport(AppKitPlus)
import AppKitPlus
#endif

/// What the Find navigator's query field holds: the text typed there and, on macOS, the find
/// patterns inserted among it — AppKitPlus's tokens, Digits, Any Word Characters and the rest.
///
/// A term without patterns searches as plain text always has. A term with patterns goes to the
/// engine as a regular expression; `searchText(literalMatchMode:isRegularExpression:)` makes it.
public struct FindQueryTerm: Hashable, Sendable {
    #if canImport(AppKitPlus)
    /// The field's content: its text and pattern tokens, in order.
    public let components: NSFindPatternComponents

    public init(components: NSFindPatternComponents) {
        self.components = components
    }

    /// A term of text alone.
    public init(text: String = "") {
        self.init(components: NSFindPatternComponents(string: text))
    }

    /// The text, with the tokens left out.
    public var plainText: String { components.plainText }

    public var hasPatterns: Bool { components.hasPatterns }
    #else
    /// The text.
    public let plainText: String

    /// A term of text alone.
    public init(text: String = "") {
        self.plainText = text
    }

    /// Patterns are inserted with AppKitPlus's field, which this platform does not have.
    public var hasPatterns: Bool { false }
    #endif

    /// Whether there is nothing to search for: no pattern, and no text but white space.
    public var isEmpty: Bool {
        !hasPatterns && plainText.allSatisfy(\.isWhitespace)
    }
}

extension FindQueryTerm: ExpressibleByStringLiteral {
    public init(stringLiteral text: String) {
        self.init(text: text)
    }
}

// MARK: - Searching

/// What one search sends the engine for a query's term: the text, and the match mode it is read
/// with.
public struct FindSearchText: Hashable, Sendable {
    public let text: String
    public let matchMode: RuntimeInterfaceSearchMatchMode

    public init(text: String, matchMode: RuntimeInterfaceSearchMatchMode) {
        self.text = text
        self.matchMode = matchMode
    }
}

extension FindQueryTerm {
    /// The term with the white space before its first text and after its last one cut off: the
    /// ends of the field. White space next to a pattern inside it is part of the query.
    var trimmed: FindQueryTerm {
        #if canImport(AppKitPlus)
        var trimmedComponents = components.components
        if case .text(let text)? = trimmedComponents.first {
            trimmedComponents[0] = .text(String(text.drop(while: \.isWhitespace)))
        }
        if case .text(let text)? = trimmedComponents.last {
            let trailingWhitespaceCount = text.reversed().prefix(while: \.isWhitespace).count
            trimmedComponents[trimmedComponents.count - 1] = .text(String(text.dropLast(trailingWhitespaceCount)))
        }
        return FindQueryTerm(components: NSFindPatternComponents(trimmedComponents))
        #else
        return FindQueryTerm(text: plainText.trimmingCharacters(in: .whitespacesAndNewlines))
        #endif
    }

    /// What a search sends the engine for this term, its ends trimmed.
    ///
    /// Without patterns, the text, read under `literalMatchMode` — or as a regular expression when
    /// `isRegularExpression`. With patterns, always a regular expression, the engine's wire format
    /// for anything that is not literal text, so an older RuntimeViewer on the other end searches
    /// it too: the text escaped to match itself and each token its pattern, then bounded the way
    /// `literalMatchMode` bounds plain text — the engine's identifier boundaries, so that Matching
    /// Word means one thing with patterns and without. When `isRegularExpression`, the text is
    /// regular expression syntax already and goes in as it is, unbounded.
    func searchText(literalMatchMode: RuntimeInterfaceSearchMatchMode, isRegularExpression: Bool) -> FindSearchText {
        let trimmedTerm = trimmed
        #if canImport(AppKitPlus)
        if trimmedTerm.hasPatterns {
            if isRegularExpression {
                return FindSearchText(text: trimmedTerm.components.regularExpressionPattern(escapingText: false), matchMode: .regularExpression)
            }
            let expression = trimmedTerm.components.regularExpressionPattern(escapingText: true)
            return FindSearchText(text: RuntimeTextPattern.regularExpression(expression, boundedAs: literalMatchMode), matchMode: .regularExpression)
        }
        #endif
        return FindSearchText(text: trimmedTerm.plainText, matchMode: isRegularExpression ? .regularExpression : literalMatchMode)
    }

    /// What two terms are compared by when one replaces the other in the recent queries: the text,
    /// or the regular expression the patterns make. Two queries typed apart carry tokens with
    /// identifiers of their own and are still the same search.
    var searchIdentity: String {
        #if canImport(AppKitPlus)
        if hasPatterns {
            return "patterns:" + components.regularExpressionPattern
        }
        #endif
        return "text:" + plainText
    }
}

// MARK: - Coding

/// A term is stored as its components' property list: a string for each run of text and, for each
/// pattern, a dictionary of strings and booleans under the keys Xcode's find field writes to the
/// pasteboard. AppKitPlus reads that form back, so the patterns' properties are its to name.
extension FindQueryTerm: Codable {
    public init(from decoder: any Decoder) throws {
        let storedComponents = try decoder.singleValueContainer().decode([StoredComponent].self)
        #if canImport(AppKitPlus)
        let propertyList: [Any] = storedComponents.map { storedComponent -> Any in
            switch storedComponent {
            case .text(let text):
                return text
            case .pattern(let properties):
                return properties.mapValues { value -> Any in
                    switch value {
                    case .string(let string): string
                    case .boolean(let boolean): boolean
                    }
                }
            }
        }
        guard let components = NSFindPatternComponents(propertyListRepresentation: propertyList) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "A pattern has no regular expression."))
        }
        self.init(components: components)
        #else
        self.init(text: storedComponents.compactMap { storedComponent -> String? in
            if case .text(let text) = storedComponent { return text }
            return nil
        }.joined())
        #endif
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        #if canImport(AppKitPlus)
        let storedComponents = components.propertyListRepresentation.compactMap { element -> StoredComponent? in
            if let text = element as? String {
                return .text(text)
            }
            guard let properties = element as? [String: Any] else { return nil }
            return .pattern(properties.compactMapValues { value -> StoredValue? in
                if let string = value as? String { return .string(string) }
                if let boolean = value as? Bool { return .boolean(boolean) }
                return nil
            })
        }
        try container.encode(storedComponents)
        #else
        try container.encode([StoredComponent.text(plainText)])
        #endif
    }

    /// A run of text, or a pattern's property-list dictionary.
    private enum StoredComponent: Codable {
        case text(String)
        case pattern([String: StoredValue])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .pattern(try container.decode([String: StoredValue].self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text):
                try container.encode(text)
            case .pattern(let properties):
                try container.encode(properties)
            }
        }
    }

    /// The values a pattern's dictionary holds.
    private enum StoredValue: Codable {
        case string(String)
        case boolean(Bool)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let boolean = try? container.decode(Bool.self) {
                self = .boolean(boolean)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let string):
                try container.encode(string)
            case .boolean(let boolean):
                try container.encode(boolean)
            }
        }
    }
}
