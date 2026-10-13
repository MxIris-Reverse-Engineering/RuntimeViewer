import AppKit
import AppKitPlus
import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// What the Find navigator sends the engine for the query field's term — proposal
/// `find-patterns-and-recent-queries`: text alone as before, a term with find patterns as a
/// regular expression bounded the way its match style bounds plain text, and the term stored as the
/// property list Xcode's find field writes.
@Suite("FindQueryTerm")
struct FindQueryTermTests {
    private static func standardPattern(_ title: String) throws -> NSFindPattern {
        try #require(NSFindPattern.standardPatternGroups.flatMap { $0 }.first { $0.title == title })
    }

    private static func term(_ components: [NSFindPatternComponents.Component]) -> FindQueryTerm {
        FindQueryTerm(components: NSFindPatternComponents(components))
    }

    // MARK: - Search text

    @Test("a term without patterns is sent as its text, trimmed, under the query's match style")
    func plainTextIsSentAsBefore() {
        var query = FindQuery(text: "  NSView \n")
        #expect(query.textSearchText == FindSearchText(text: "NSView", matchMode: .containing))
        query.textMatchStyle = .matchingWord
        #expect(query.textSearchText == FindSearchText(text: "NSView", matchMode: .matchingWord))
        query.mode = .regularExpression
        #expect(query.textSearchText == FindSearchText(text: "NSView", matchMode: .regularExpression))
        query.memberMatchStyle = .startingWith
        #expect(query.memberSearchText == FindSearchText(text: "NSView", matchMode: .startingWith))
        query.memberMatchStyle = .regularExpression
        #expect(query.memberSearchText == FindSearchText(text: "NSView", matchMode: .regularExpression))
        #expect(query.relationshipSearchText == FindSearchText(text: "NSView", matchMode: .matchingWord))
    }

    @Test("a term with patterns is a regular expression: the text escaped, each token its pattern, bounded like the match style")
    func patternsMakeABoundedRegularExpression() throws {
        let digits = try Self.standardPattern("Digits").withIdentifier("digits")
        let unboundedExpression = #"build\.(\d+)"#
        var query = FindQuery(term: Self.term([.text("build."), .pattern(digits)]))
        #expect(query.textSearchText == FindSearchText(text: unboundedExpression, matchMode: .regularExpression))

        for textMatchStyle in FindTextMatchStyle.allCases {
            query.textMatchStyle = textMatchStyle
            let boundedExpression = RuntimeTextPattern.regularExpression(unboundedExpression, boundedAs: textMatchStyle.matchMode)
            #expect(query.textSearchText == FindSearchText(text: boundedExpression, matchMode: .regularExpression), "\(textMatchStyle)")
            #expect(query.relationshipSearchText == FindSearchText(text: boundedExpression, matchMode: .regularExpression), "\(textMatchStyle)")
        }
        query.memberMatchStyle = .endingWith
        let memberExpression = RuntimeTextPattern.regularExpression(unboundedExpression, boundedAs: .endingWith)
        #expect(query.memberSearchText == FindSearchText(text: memberExpression, matchMode: .regularExpression))
    }

    @Test("with patterns in a regular expression the text is regular expression syntax, put in as it is and unbounded")
    func regularExpressionTextIsNotEscaped() throws {
        let digits = try Self.standardPattern("Digits").withIdentifier("digits")
        var query = FindQuery(mode: .regularExpression, term: Self.term([.text("^v."), .pattern(digits), .text("$")]), textMatchStyle: .matchingWord)
        #expect(query.textSearchText == FindSearchText(text: #"^v.(\d+)$"#, matchMode: .regularExpression))
        query.mode = .members
        query.memberMatchStyle = .regularExpression
        #expect(query.memberSearchText == FindSearchText(text: #"^v.(\d+)$"#, matchMode: .regularExpression))
    }

    @Test("only the ends of the field are trimmed, not the white space next to a pattern")
    func onlyTheEndsAreTrimmed() throws {
        let word = try Self.standardPattern("Any Word Characters").withIdentifier("word")
        let term = Self.term([.text("  a "), .pattern(word), .text(" b \n")])
        #expect(term.trimmed.components.components == [.text("a "), .pattern(word), .text(" b")])
        #expect(FindQuery(term: term).textSearchText.text == #"a (\w+) b"#)

        let lonePattern = Self.term([.text(" "), .pattern(word), .text(" ")])
        #expect(FindQuery(term: lonePattern).textSearchText.text == #"(\w+)"#)
    }

    @Test("a term is empty with no pattern and nothing but white space")
    func emptiness() throws {
        #expect(FindQueryTerm().isEmpty)
        #expect(FindQueryTerm(text: " \n\t").isEmpty)
        #expect(!FindQueryTerm(text: "a").isEmpty)
        #expect(!Self.term([.text(" "), .pattern(try Self.standardPattern("Digits"))]).isEmpty)
        #expect(FindQuery(text: "  ").isEmpty)
    }

    @Test("the patterns' regular expression finds what the engine finds for the same words as plain text")
    func patternsMatchLikeTheirWords() throws {
        // `NSMutable` then a word: what Matching Word finds with a pattern is a whole identifier,
        // as it is for `NSMutableString` typed out.
        let word = try Self.standardPattern("Any Word Characters").withIdentifier("word")
        let query = FindQuery(term: Self.term([.text("NSMutable"), .pattern(word)]), textMatchStyle: .matchingWord, isCaseSensitive: true)
        let searchText = query.textSearchText
        let pattern = try RuntimeTextPattern(text: searchText.text, matchMode: searchText.matchMode, isCaseSensitive: true)
        let text = "NSMutableString *string; _NSMutableStorage $NSMutableValue NSMutableArray<id>"
        #expect(pattern.ranges(in: text).map { (text as NSString).substring(with: $0) } == ["NSMutableString", "NSMutableArray"])
    }

    // MARK: - Identity

    @Test("two terms typed apart are the same search, whatever identifiers their tokens have")
    func searchIdentityIgnoresTokenIdentifiers() throws {
        let digits = try Self.standardPattern("Digits")
        let backreference = Self.term([.text("v"), .pattern(digits.withIdentifier("first")), .pattern(digits.withIdentifier("first"))])
        let sameBackreference = Self.term([.text("v"), .pattern(digits.withIdentifier("second")), .pattern(digits.withIdentifier("second"))])
        let twoGroups = Self.term([.text("v"), .pattern(digits.withIdentifier("first")), .pattern(digits.withIdentifier("other"))])
        #expect(backreference != sameBackreference)
        #expect(backreference.searchIdentity == sameBackreference.searchIdentity)
        #expect(backreference.searchIdentity != twoGroups.searchIdentity)
        #expect(FindQueryTerm(text: #"v(\d+)(?:\1)"#).searchIdentity != backreference.searchIdentity, "text that reads like the expression is another search")
    }

    // MARK: - Coding

    @Test("a query is stored with every setting, its patterns as the property list Xcode writes, and reads back equal")
    func codingRoundTrip() throws {
        let digits = try Self.standardPattern("Digits").withIdentifier("digits")
        let query = FindQuery(
            mode: .members,
            term: Self.term([.text("x"), .pattern(digits)]),
            textMatchStyle: .endingWith,
            memberMatchStyle: .regularExpression,
            memberKindFilter: .kind(.objcMethod),
            isCaseSensitive: true,
            scope: .images(["/usr/lib/libobjc.A.dylib"])
        )
        let data = try JSONEncoder().encode(query)
        #expect(try JSONDecoder().decode(FindQuery.self, from: data) == query)
        for scope in [FindScope.allIndexedImages, .currentImage] {
            var otherScope = query
            otherScope.scope = scope
            #expect(try JSONDecoder().decode(FindQuery.self, from: JSONEncoder().encode(otherScope)) == otherScope)
        }

        let storedTerm = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(query.term)) as? [Any])
        #expect(storedTerm.first as? String == "x")
        let storedPattern = try #require(storedTerm.last as? [String: Any])
        #expect(storedPattern["NSFindPatternRegularExpressionKey"] as? String == #"\d+"#)
        #expect(storedPattern["NSFindPatternTokenUniqueIDKey"] as? String == "digits")
        #expect(storedPattern["NSFindPatternTokenAllowsBackreferencesKey"] as? Bool == true)
    }

    @Test("a stored pattern without a regular expression does not decode")
    func malformedPatternDoesNotDecode() {
        let data = Data(#"["x", {"NSFindPatternDisplayStringKey": "Digits"}]"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(FindQueryTerm.self, from: data) }
    }
}
