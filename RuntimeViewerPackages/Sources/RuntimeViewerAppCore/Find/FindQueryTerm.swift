import Foundation
import RuntimeViewerCore

/// What the Find navigator's query field holds: the text typed there and the find patterns inserted
/// among it — Digits, Any Word Characters and the rest, which the field shows as tokens.
///
/// A term without patterns searches as plain text always has. A term with patterns goes to the
/// engine as a regular expression; `searchText(literalMatchMode:isRegularExpression:)` makes it,
/// by AppKitPlus's rules (`regularExpressionPattern(escapingText:)`). The query field itself is
/// AppKitPlus's `NSFindPatternSearchField`; RuntimeViewerAppUI turns its content into a term and back.
public struct FindQueryTerm: Hashable, Sendable {
    /// One part of a term: text, or a pattern token.
    public enum Component: Hashable, Sendable {
        /// Text, which the term's regular expression matches literally.
        case text(String)
        /// A pattern token.
        case pattern(FindPattern)
    }

    /// The field's content: its text and pattern tokens, in order. Never holds empty text.
    public let components: [Component]

    /// A term of `components` in order. Empty text is left out; adjacent text is kept apart, as
    /// AppKitPlus's `NSFindPatternComponents` keeps it.
    public init(components: [Component]) {
        self.components = components.filter { component in
            if case .text(let text) = component {
                return !text.isEmpty
            }
            return true
        }
    }

    /// A term of text alone.
    public init(text: String = "") {
        self.init(components: [.text(text)])
    }

    /// The text, with the tokens left out.
    public var plainText: String {
        components.reduce(into: "") { plainText, component in
            if case .text(let text) = component {
                plainText += text
            }
        }
    }

    /// Whether any component is a pattern.
    public var hasPatterns: Bool {
        components.contains { component in
            if case .pattern = component {
                return true
            }
            return false
        }
    }

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

// MARK: - Regular expression

/// The rules AppKitPlus's `NSFindPatternComponents` makes a regular expression by
/// (`NSFindPattern.m`), rewritten rule for rule, a UTF-16 code unit at a time as the original
/// reads `unichar`s. `FindPatternParityTests` holds the two equal.
extension FindQueryTerm {
    /// The regular expression the term makes —
    /// `-[NSFindPatternComponents regularExpressionPatternEscapingText:]`:
    ///
    /// - Text is escaped to match itself when `escapingText`; otherwise it is regular expression
    ///   syntax and goes in as it is, its own capture groups counted.
    /// - A pattern without backreferences goes in as it is.
    /// - A pattern with backreferences is a capture group the first time its identifier appears and
    ///   `(?:\N)`, a backreference to that group, every later time; a pattern without an identifier
    ///   is a group of its own.
    /// - Group numbers count the groups the patterns' own expressions open.
    func regularExpressionPattern(escapingText: Bool) -> String {
        var expression = ""
        var groupNumbersByIdentifier: [String: Int] = [:]
        var openedGroupCount = 0
        for component in components {
            switch component {
            case .text(let text):
                if escapingText {
                    expression += Self.escapedText(text)
                } else {
                    expression += text
                    openedGroupCount += Self.captureGroupCount(in: text)
                }
            case .pattern(let pattern):
                if !pattern.allowsBackreferences {
                    expression += pattern.regularExpression
                    openedGroupCount += Self.captureGroupCount(in: pattern.regularExpression)
                } else if let identifier = pattern.identifier, let groupNumber = groupNumbersByIdentifier[identifier] {
                    expression += "(?:\\\(groupNumber))"
                } else {
                    openedGroupCount += 1
                    if let identifier = pattern.identifier {
                        groupNumbersByIdentifier[identifier] = openedGroupCount
                    }
                    expression += "(\(pattern.regularExpression))"
                    openedGroupCount += Self.captureGroupCount(in: pattern.regularExpression)
                }
            }
        }
        return expression
    }

    private static let backslash = UTF16.CodeUnit(UInt8(ascii: "\\"))
    private static let openingParenthesis = UTF16.CodeUnit(UInt8(ascii: "("))
    private static let questionMark = UTF16.CodeUnit(UInt8(ascii: "?"))
    private static let lessThanSign = UTF16.CodeUnit(UInt8(ascii: "<"))
    private static let openingBracket = UTF16.CodeUnit(UInt8(ascii: "["))
    private static let closingBracket = UTF16.CodeUnit(UInt8(ascii: "]"))
    private static let caret = UTF16.CodeUnit(UInt8(ascii: "^"))

    /// The characters `escapedText(_:)` puts a backslash before.
    private static let specialCodeUnits = Set("$()*+./?[\\]^{|}".utf16)

    /// `text` with a backslash before each of `$()*+./?[\]^{|}`, so that it matches itself —
    /// `_escapeStringIntoMutableString`.
    static func escapedText(_ text: String) -> String {
        var escapedCodeUnits: [UTF16.CodeUnit] = []
        escapedCodeUnits.reserveCapacity(text.utf16.count)
        for codeUnit in text.utf16 {
            if specialCodeUnits.contains(codeUnit) {
                escapedCodeUnits.append(backslash)
            }
            escapedCodeUnits.append(codeUnit)
        }
        return String(decoding: escapedCodeUnits, as: UTF16.self)
    }

    /// The capture groups `expression` opens — `NSPLFindPatternCaptureGroupCount`: every `(` that
    /// is not escaped, not inside a bracket expression and not the start of `(?…)`, except a named
    /// group, `(?<name>…)`.
    static func captureGroupCount(in expression: String) -> Int {
        let codeUnits = Array(expression.utf16)
        var count = 0
        var isInsideBrackets = false
        var index = 0
        while index < codeUnits.count {
            let codeUnit = codeUnits[index]
            if codeUnit == backslash {
                index += 2
                continue
            }
            if isInsideBrackets {
                if codeUnit == closingBracket {
                    isInsideBrackets = false
                }
                index += 1
                continue
            }
            if codeUnit == openingBracket {
                isInsideBrackets = true
                // A `]` straight after `[` or `[^` belongs to the set.
                if index + 1 < codeUnits.count, codeUnits[index + 1] == caret {
                    index += 1
                }
                if index + 1 < codeUnits.count, codeUnits[index + 1] == closingBracket {
                    index += 1
                }
                index += 1
                continue
            }
            if codeUnit == openingParenthesis {
                if index + 1 >= codeUnits.count || codeUnits[index + 1] != questionMark {
                    count += 1
                } else if index + 3 < codeUnits.count, codeUnits[index + 2] == lessThanSign, isLetter(codeUnits[index + 3]) {
                    count += 1
                }
            }
            index += 1
        }
        return count
    }

    /// Whether `codeUnit` is a letter, as `NSCharacterSet.letterCharacterSet` decides for a
    /// `unichar`; half of a surrogate pair is not.
    private static func isLetter(_ codeUnit: UTF16.CodeUnit) -> Bool {
        guard let scalar = Unicode.Scalar(codeUnit) else { return false }
        return CharacterSet.letters.contains(scalar)
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
        var trimmedComponents = components
        if case .text(let text)? = trimmedComponents.first {
            trimmedComponents[0] = .text(String(text.drop(while: \.isWhitespace)))
        }
        if case .text(let text)? = trimmedComponents.last {
            let trailingWhitespaceCount = text.reversed().prefix(while: \.isWhitespace).count
            trimmedComponents[trimmedComponents.count - 1] = .text(String(text.dropLast(trailingWhitespaceCount)))
        }
        return FindQueryTerm(components: trimmedComponents)
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
        if trimmedTerm.hasPatterns {
            if isRegularExpression {
                return FindSearchText(text: trimmedTerm.regularExpressionPattern(escapingText: false), matchMode: .regularExpression)
            }
            let expression = trimmedTerm.regularExpressionPattern(escapingText: true)
            return FindSearchText(text: RuntimeTextPattern.regularExpression(expression, boundedAs: literalMatchMode), matchMode: .regularExpression)
        }
        return FindSearchText(text: trimmedTerm.plainText, matchMode: isRegularExpression ? .regularExpression : literalMatchMode)
    }

    /// What two terms are compared by when one replaces the other in the recent queries: the text,
    /// or the regular expression the patterns make. Two queries typed apart carry tokens with
    /// identifiers of their own and are still the same search.
    var searchIdentity: String {
        if hasPatterns {
            return "patterns:" + regularExpressionPattern(escapingText: true)
        }
        return "text:" + plainText
    }
}

// MARK: - Property list

/// The form Xcode's find field writes to the pasteboard, which AppKitPlus's
/// `NSFindPatternComponents` reads and writes too: a string for each run of text and a dictionary
/// for each pattern (`FindPattern.propertyListRepresentation`).
extension FindQueryTerm {
    /// The term as a property list: an array of strings and dictionaries, one per component —
    /// `-[NSFindPatternComponents propertyListRepresentation]`.
    var propertyListRepresentation: [Any] {
        components.map { component -> Any in
            switch component {
            case .text(let text):
                text
            case .pattern(let pattern):
                pattern.propertyListRepresentation
            }
        }
    }

    /// A term from a property list — `-[NSFindPatternComponents initWithPropertyListRepresentation:]`:
    /// `nil` when `propertyList` is not an array, or when an element is neither a string nor a
    /// dictionary with a string regular expression.
    init?(propertyListRepresentation propertyList: Any) {
        guard let elements = propertyList as? [Any] else { return nil }
        var components: [Component] = []
        components.reserveCapacity(elements.count)
        for element in elements {
            if let text = element as? String {
                components.append(.text(text))
            } else if let properties = element as? [String: Any], let pattern = FindPattern(propertyListRepresentation: properties) {
                components.append(.pattern(pattern))
            } else {
                return nil
            }
        }
        self.init(components: components)
    }
}

// MARK: - Coding

/// A term is stored as its property list: a string for each run of text and, for each pattern, a
/// dictionary of strings and booleans under the keys Xcode's find field writes to the pasteboard.
/// The recent queries of every earlier version are in this form, AppKitPlus's own, and read back.
extension FindQueryTerm: Codable {
    public init(from decoder: any Decoder) throws {
        let storedComponents = try decoder.singleValueContainer().decode([StoredComponent].self)
        let propertyList: [Any] = storedComponents.map { storedComponent -> Any in
            switch storedComponent {
            case .text(let text):
                text
            case .pattern(let properties):
                properties.mapValues(\.propertyListValue)
            }
        }
        guard let term = FindQueryTerm(propertyListRepresentation: propertyList) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "A pattern has no regular expression."))
        }
        self = term
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let storedComponents = components.map { component -> StoredComponent in
            switch component {
            case .text(let text):
                .text(text)
            case .pattern(let pattern):
                .pattern(pattern.propertyListRepresentation.compactMapValues(StoredValue.init(propertyListValue:)))
            }
        }
        try container.encode(storedComponents)
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

        /// `value` when it is a string or a boolean, the only kinds a pattern's dictionary holds.
        init?(propertyListValue value: Any) {
            if let string = value as? String {
                self = .string(string)
            } else if let boolean = value as? Bool {
                self = .boolean(boolean)
            } else {
                return nil
            }
        }

        var propertyListValue: Any {
            switch self {
            case .string(let string):
                string
            case .boolean(let boolean):
                boolean
            }
        }

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
