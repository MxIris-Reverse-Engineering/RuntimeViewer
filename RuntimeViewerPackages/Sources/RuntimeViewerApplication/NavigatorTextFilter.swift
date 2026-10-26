import Foundation

/// The filter of a sidebar page: the tokens in its filter field, each comparing a row's name with a value in one way,
/// and the text still being typed after them.
///
/// It is the filter of Xcode's navigators — the Project navigator's filter bar — taken from Xcode 27
/// (`DVTTextFilterExpressionPresentationDelegate`, and DVTFoundation's `DVTTextFilterExpression` for the comparisons;
/// the reverse-engineering record is in `/Volumes/RE/Xcode/27.2/README.md`, "Navigator text filter tokens"). A row
/// passes when its name satisfies every term, the terms the typed text parses into included: the tokens and the typed
/// text always combine with AND, as in Xcode's navigators, which never offer ANY.
///
/// Typed text parses the way Xcode parses it (`terms(parsing:)`), with one addition: `!x` stands for Does Not Contain.
/// Xcode offers that comparison only from a token's menu, and turns such a token back into a plain `x` when it is
/// edited, which silently makes it Contains.
public struct NavigatorTextFilter: Hashable, Sendable {
    /// How a term compares a name with its value: Xcode's text comparisons, without Equals, which no typed text
    /// produces.
    public enum Comparison: Hashable, Sendable, CaseIterable {
        /// The name contains the value, ignoring case and diacritics.
        case contains
        /// The name does not contain the value, ignoring case and diacritics.
        case doesNotContain
        /// The name begins with the value, ignoring case.
        case beginsWith
        /// The name ends with the value, ignoring case.
        case endsWith
        /// Somewhere in the name, the value matches as a wildcard pattern, ignoring case: `*` stands for any run of
        /// characters, `?` for any one character, and `\` makes the character after it literal.
        case like
    }

    /// One condition on a name.
    public struct Term: Hashable, Sendable {
        public var comparison: Comparison

        public var value: String

        public init(comparison: Comparison, value: String) {
            self.comparison = comparison
            self.value = value
        }
    }

    /// The terms of the field's tokens, in order.
    public var terms: [Term]

    /// The text after the last token that has not become a token yet. It narrows the list as well, parsed the way a
    /// token's text is.
    public var typedText: String

    public init(terms: [Term] = [], typedText: String = "") {
        self.terms = terms
        self.typedText = typedText
    }

    /// No token and no text.
    public static let empty = NavigatorTextFilter()

    /// The terms the typed text stands for.
    public var typedTerms: [Term] {
        Self.terms(parsing: typedText)
    }

    /// Every condition: the tokens' terms, then the typed text's.
    public var allTerms: [Term] {
        terms + typedTerms
    }

    /// Whether the filter has no condition — no token, and no typed text but white space.
    public var isEmpty: Bool {
        terms.isEmpty && typedTerms.isEmpty
    }
}

// MARK: - Parsing

extension NavigatorTextFilter {
    /// The characters that make a fragment more than plain text, as in Xcode: `*`, `?` and `\`.
    private static let specialCharacters: Set<Character> = ["*", "?", "\\"]

    /// The terms `text` stands for, parsed as Xcode's `DVTFilterExpressionForTextBySplittingIntoSubexpressions` parses
    /// the text of a filter field:
    ///
    /// - The text splits at white space into fragments; `\ ` stands for a space inside a fragment, and empty fragments
    ///   are dropped.
    /// - A fragment without `*`, `?` or `\` is Contains.
    /// - `*x` is Ends With `x`, and `x*` is Begins With `x`, when `x` has none of the three. A lone `*` is Ends With
    ///   nothing, which matches no name — as in Xcode.
    /// - Any other fragment with one of the three is Like, the fragment as it is.
    /// - `!x`, `x` being plain text, is Does Not Contain `x`. Xcode has no typed form for it; a lone `!` stays
    ///   Contains `!`.
    public static func terms(parsing text: String) -> [Term] {
        fragments(of: text).map { term(forFragment: $0) }
    }

    /// The text that `terms(parsing:)` turns back into `term` — what its token reads as when it is edited, read aloud
    /// or copied as text. A space in the value is written `\ `.
    public static func editingString(for term: Term) -> String {
        let value = term.value.replacingOccurrences(of: " ", with: "\\ ")
        switch term.comparison {
        case .contains,
             .like:
            return value
        case .doesNotContain:
            return "!" + value
        case .beginsWith:
            return value + "*"
        case .endsWith:
            return "*" + value
        }
    }

    /// `DVTTextFragmentsForStringPreservingEscapedSpaces`: the text split at white space, `\ ` kept as a space.
    static func fragments(of text: String) -> [String] {
        var fragments: [String] = []
        var currentFragment = ""
        var characterIndex = text.startIndex
        while characterIndex < text.endIndex {
            let character = text[characterIndex]
            let nextCharacterIndex = text.index(after: characterIndex)
            if character == "\\", nextCharacterIndex < text.endIndex, text[nextCharacterIndex] == " " {
                currentFragment.append(" ")
                characterIndex = text.index(after: nextCharacterIndex)
                continue
            }
            if character.isWhitespace {
                if !currentFragment.isEmpty {
                    fragments.append(currentFragment)
                    currentFragment = ""
                }
            } else {
                currentFragment.append(character)
            }
            characterIndex = nextCharacterIndex
        }
        if !currentFragment.isEmpty {
            fragments.append(currentFragment)
        }
        return fragments
    }

    /// The comparison of one fragment — the block Xcode's `_comparisonTypeFor` runs — plus the `!x` form.
    static func term(forFragment fragment: String) -> Term {
        func isPlainText(_ text: Substring) -> Bool {
            !text.contains { specialCharacters.contains($0) }
        }
        if isPlainText(fragment[...]) {
            if fragment.count > 1, fragment.first == "!" {
                return Term(comparison: .doesNotContain, value: String(fragment.dropFirst()))
            }
            return Term(comparison: .contains, value: fragment)
        }
        if fragment.hasPrefix("*"), isPlainText(fragment.dropFirst()) {
            return Term(comparison: .endsWith, value: String(fragment.dropFirst()))
        }
        if fragment.hasSuffix("*"), isPlainText(fragment.dropLast()) {
            return Term(comparison: .beginsWith, value: String(fragment.dropLast()))
        }
        return Term(comparison: .like, value: fragment)
    }
}

// MARK: - Matching

extension NavigatorTextFilter {
    /// The filter's conditions made ready to test many names: each comparison's options settled and every Like
    /// pattern compiled once. Build one per filter pass, off the main thread if the pass runs there.
    public func makeMatcher(isCaseSensitive: Bool = false) -> Matcher {
        Matcher(terms: allTerms, isCaseSensitive: isCaseSensitive)
    }

    /// Terms made ready to test many names.
    public struct Matcher: Sendable {
        /// The terms, in the filter's order.
        public let compiledTerms: [CompiledTerm]

        /// `terms` ready for testing. With `isCaseSensitive`, every comparison tells upper from lower case — the
        /// sidebar's Match Case; diacritics are treated as without it.
        public init(terms: [Term], isCaseSensitive: Bool = false) {
            self.compiledTerms = terms.map { CompiledTerm(term: $0, isCaseSensitive: isCaseSensitive) }
        }

        /// Whether there is no term to test, so that every name passes.
        public var isEmpty: Bool {
            compiledTerms.isEmpty
        }

        /// Whether `name` satisfies every term.
        public func matches(_ name: String) -> Bool {
            compiledTerms.allSatisfy { $0.matches(name) }
        }
    }

    /// One term made ready to test many names.
    public struct CompiledTerm: Sendable {
        public let term: Term

        /// The options Xcode compares with (`_predicateForTextExpression:` in DVTFoundation): `localizedStandardContains`
        /// — case and diacritics ignored — for Contains and Does Not Contain; for Begins With and Ends With an anchored
        /// search that ignores case only (options 9 and 13).
        private let compareOptions: String.CompareOptions

        /// A Like pattern as a regular expression that may match anywhere in a name, Xcode's `like[c]` against the
        /// value wrapped in `*`. `nil` for the other comparisons, and for a pattern that does not compile.
        private let likeExpression: NSRegularExpression?

        public init(term: Term, isCaseSensitive: Bool) {
            self.term = term
            let caseOptions: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
            switch term.comparison {
            case .contains,
                 .doesNotContain:
                compareOptions = caseOptions.union(.diacriticInsensitive)
            case .beginsWith:
                compareOptions = caseOptions.union(.anchored)
            case .endsWith:
                compareOptions = caseOptions.union([.anchored, .backwards])
            case .like:
                compareOptions = caseOptions
            }
            if term.comparison == .like {
                likeExpression = try? NSRegularExpression(
                    pattern: Self.regularExpressionPattern(forWildcardPattern: term.value),
                    options: isCaseSensitive ? [.dotMatchesLineSeparators] : [.caseInsensitive, .dotMatchesLineSeparators]
                )
            } else {
                likeExpression = nil
            }
        }

        /// Whether the term is Does Not Contain — the one comparison a name satisfies by lacking the value.
        public var isExclusion: Bool {
            term.comparison == .doesNotContain
        }

        /// Whether `name` satisfies the term. An empty value matches nothing, Does Not Contain excepted — the lone
        /// `*` of Xcode's parser is Ends With nothing, and `rangeOfString:` finds no empty string.
        public func matches(_ name: String) -> Bool {
            switch term.comparison {
            case .contains,
                 .beginsWith,
                 .endsWith:
                return name.range(of: term.value, options: compareOptions, locale: .current) != nil
            case .doesNotContain:
                return name.range(of: term.value, options: compareOptions, locale: .current) == nil
            case .like:
                guard let likeExpression else { return false }
                return likeExpression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            }
        }

        /// The wildcard pattern as a regular expression: `*` any run of characters, `?` any one, `\` the next
        /// character literally, everything else literally.
        static func regularExpressionPattern(forWildcardPattern wildcardPattern: String) -> String {
            var regularExpressionPattern = ""
            var isEscaping = false
            for character in wildcardPattern {
                if isEscaping {
                    regularExpressionPattern += NSRegularExpression.escapedPattern(for: String(character))
                    isEscaping = false
                    continue
                }
                switch character {
                case "\\":
                    isEscaping = true
                case "*":
                    regularExpressionPattern += ".*"
                case "?":
                    regularExpressionPattern += "."
                default:
                    regularExpressionPattern += NSRegularExpression.escapedPattern(for: String(character))
                }
            }
            if isEscaping {
                regularExpressionPattern += NSRegularExpression.escapedPattern(for: "\\")
            }
            return regularExpressionPattern
        }
    }
}
