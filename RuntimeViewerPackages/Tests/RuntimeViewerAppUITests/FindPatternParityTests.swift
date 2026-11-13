import AppKit
import AppKitPlus
import Foundation
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport
@testable import RuntimeViewerAppUI

/// RuntimeViewerAppCore's copy of AppKitPlus's find pattern rules against AppKitPlus itself (proposal
/// `draft-app-core-ui-split`): one property list read by both, and the regular expressions, text and property lists
/// they make compared. When an AppKitPlus update changes a rule, a case here fails; carry the change over to
/// `FindQueryTerm`.
@Suite("Find pattern parity with AppKitPlus")
struct FindPatternParityTests {
    /// A pattern whose expression opens groups of its own: a lookahead, a plain group, a named group, a parenthesis in
    /// a bracket expression, an escaped one, and an inline option.
    private static let grouped = FindPattern(regularExpression: #"(?=x)(a)(?<name>b)[(]\((?i:c)"#, title: "Grouped", tokenTitle: "G", identifier: "grouped")

    /// Terms that between them take every rule's branch.
    static let terms: [FindQueryTerm] = [
        FindQueryTerm(),
        FindQueryTerm(text: #"$()*+./?[\]^{|}-a"#),
        FindQueryTerm(components: [.pattern(.digits(identifier: "first")), .text("-"), .pattern(.anyWordCharacters(identifier: "second")), .text("-"), .pattern(.digits(identifier: "first"))]),
        FindQueryTerm(components: [.pattern(.digits()), .text("-"), .pattern(.digits())]),
        FindQueryTerm(components: [.pattern(.wordBreak(identifier: "break")), .text("a"), .pattern(.tab(identifier: "tab")), .pattern(.wordBreak(identifier: "break"))]),
        FindQueryTerm(components: [.pattern(grouped), .pattern(.digits(identifier: "digits")), .pattern(.digits(identifier: "digits"))]),
        FindQueryTerm(components: [.text("(x)"), .pattern(.digits(identifier: "digits")), .text(#"\1"#), .pattern(.digits(identifier: "digits"))]),
        // Every standard pattern, each a token of its own, then each again.
        FindQueryTerm(components: standardTokens + [.text("(again)")] + standardTokens),
        // Unbalanced parentheses and a bracket expression in the text.
        FindQueryTerm(components: [.text("(a(b)"), .pattern(.digits(identifier: "x")), .text("[(]"), .pattern(.anyWordCharacters(identifier: "y")), .pattern(.digits(identifier: "x"))]),
        // `[]…]` and `[^]…]`, whose first `]` belongs to the set.
        FindQueryTerm(components: [.text("[](][^](]("), .pattern(.digits(identifier: "x")), .pattern(.digits(identifier: "x"))]),
        // A named group, lookbehinds, and a name that does not start with a letter.
        FindQueryTerm(components: [.text("(?<name>a)(?<=b)(?<!c)(?<1>d)(?<é>e)"), .pattern(.digits(identifier: "x")), .pattern(.digits(identifier: "x"))]),
        // Escapes: an escaped parenthesis, and an escaped backslash before a real one.
        FindQueryTerm(components: [.text(#"\(a\)"#), .pattern(.digits(identifier: "x")), .text(#"\\("#), .pattern(.digits(identifier: "x"))]),
        // Characters outside the Basic Multilingual Plane and combining marks next to the syntax.
        FindQueryTerm(components: [.text("😀(é"), .pattern(.digits(identifier: "x")), .text("e\u{301}(?<😀>"), .pattern(.digits(identifier: "x"))]),
        // A trailing backslash, and an empty identifier, which is an identifier all the same.
        FindQueryTerm(components: [.pattern(.digits(identifier: "")), .text("\\"), .pattern(.digits(identifier: ""))]),
        // A replacement string and a negation.
        FindQueryTerm(components: [.text("set"), .pattern(.tab(identifier: "tab")), .pattern(.nonASCIICharacters(identifier: "ascii")), .pattern(.lineBreak(identifier: "line"))]),
    ]

    /// Each standard pattern as a token with an identifier of its own.
    private static let standardTokens: [FindQueryTerm.Component] = FindPattern.standardPatterns.enumerated().map { index, pattern -> FindQueryTerm.Component in
        var token = pattern
        token.identifier = "standard \(index)"
        return .pattern(token)
    }

    @Test("the patterns RuntimeViewerAppCore's tests use are Xcode's, as AppKitPlus defines them")
    func standardPatternsAreAppKitPlussOwn() {
        let appKitPlusPatterns = NSFindPattern.standardPatternGroups.flatMap { $0 }.map { FindPattern($0) }
        #expect(appKitPlusPatterns == FindPattern.standardPatterns)
    }

    @Test("both read one property list into the same regular expressions, text and property list", arguments: terms)
    func bothReadAPropertyListAlike(term: FindQueryTerm) throws {
        let propertyList = term.propertyListRepresentation
        let components = try #require(NSFindPatternComponents(propertyListRepresentation: propertyList))
        let readTerm = try #require(FindQueryTerm(propertyListRepresentation: propertyList))
        #expect(readTerm == term)
        #expect(readTerm.regularExpressionPattern(escapingText: true) == components.regularExpressionPattern(escapingText: true))
        #expect(readTerm.regularExpressionPattern(escapingText: false) == components.regularExpressionPattern(escapingText: false))
        #expect(readTerm.plainText == components.plainText)
        #expect(readTerm.hasPatterns == components.hasPatterns)
        #expect(readTerm.propertyListRepresentation as NSArray == components.propertyListRepresentation as NSArray)
    }

    @Test("both read a property list with values of the wrong kind alike, and refuse the same malformed ones")
    func bothReadOddPropertyListsAlike() throws {
        let oddPropertyLists: [[Any]] = [
            [["NSFindPatternRegularExpressionKey": "x"] as [String: Any]],
            [[
                "NSFindPatternRegularExpressionKey": "x",
                "NSFindPatternDisplayStringKey": 5,
                "NSFindPatternTokenStringKey": 7,
                "NSFindPatternTokenAllowsBackreferencesKey": "yes",
                "NSFindPatternTokenIsNegationKey": 1,
                "NSFindPatternTokenReplacementStringKey": 2,
                "NSFindPatternTokenUniqueIDKey": 3,
            ] as [String: Any]],
            [["NSFindPatternRegularExpressionKey": "x", "NSFindPatternTokenAllowsBackreferencesKey": 2] as [String: Any], "", "y"],
        ]
        for propertyList in oddPropertyLists {
            let components = try #require(NSFindPatternComponents(propertyListRepresentation: propertyList))
            let term = try #require(FindQueryTerm(propertyListRepresentation: propertyList))
            #expect(term.propertyListRepresentation as NSArray == components.propertyListRepresentation as NSArray)
            #expect(term.regularExpressionPattern(escapingText: true) == components.regularExpressionPattern(escapingText: true))
        }

        let malformedPropertyLists: [Any] = [
            "a",
            [1],
            [["NSFindPatternDisplayStringKey": "No Expression"]],
            [["NSFindPatternRegularExpressionKey": 1]],
            [["x"]],
        ]
        for propertyList in malformedPropertyLists {
            #expect(NSFindPatternComponents(propertyListRepresentation: propertyList) == nil)
            #expect(FindQueryTerm(propertyListRepresentation: propertyList) == nil)
        }
    }

    @Test("a term becomes the query field's components and comes back without losing anything", arguments: terms)
    func termRoundTripsThroughTheQueryField(term: FindQueryTerm) throws {
        let components = term.findPatternComponents
        #expect(FindQueryTerm(findPatternComponents: components) == term)
        #expect(components == NSFindPatternComponents(propertyListRepresentation: term.propertyListRepresentation))
    }
}
