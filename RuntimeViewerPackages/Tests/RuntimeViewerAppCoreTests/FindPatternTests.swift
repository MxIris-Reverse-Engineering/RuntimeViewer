import Foundation
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The find pattern rules RuntimeViewerAppCore rewrote from AppKitPlus (`NSFindPattern.m`, proposal
/// `app-core-ui-split`): the regular expression a term makes, the capture groups counted, the text escaped, and
/// the property list. The cases are AppKitPlus's own (`AppKitPlusTests/Filter Field/NSFindPatternTests.m`, 0.21.0) for
/// what was rewritten; `FindPatternParityTests` runs both implementations on the same input.
@Suite("FindPattern")
struct FindPatternTests {
    // MARK: - Regular expression

    @Test("text is escaped to match itself")
    func textIsEscapedToMatchItself() throws {
        let text = #"$()*+./?[\]^{|}-a"#
        let expression = FindQueryTerm(text: text).regularExpressionPattern(escapingText: true)
        #expect(expression == #"\$\(\)\*\+\.\/\?\[\\\]\^\{\|\}-a"#)

        let regularExpression = try NSRegularExpression(pattern: expression)
        let haystack = "xx\(text)yy" as NSString
        let match = try #require(regularExpression.firstMatch(in: haystack as String, range: NSRange(location: 0, length: haystack.length)))
        #expect(match.range == NSRange(location: 2, length: (text as NSString).length))
    }

    @Test("a pattern with backreferences is a capture group, and its later occurrences refer back to it")
    func laterOccurrencesReferBack() throws {
        let term = FindQueryTerm(components: [
            .pattern(.digits(identifier: "first")), .text("-"), .pattern(.anyWordCharacters(identifier: "second")), .text("-"), .pattern(.digits(identifier: "first")),
        ])
        let expression = term.regularExpressionPattern(escapingText: true)
        #expect(expression == #"(\d+)-(\w+)-(?:\1)"#)

        let regularExpression = try NSRegularExpression(pattern: expression)
        #expect(regularExpression.numberOfMatches(in: "12-ab-12", range: NSRange(location: 0, length: 8)) == 1)
        #expect(regularExpression.numberOfMatches(in: "12-ab-13", range: NSRange(location: 0, length: 8)) == 0)
    }

    @Test("patterns without an identifier are groups of their own")
    func patternsWithoutAnIdentifierAreGroupsOfTheirOwn() {
        let term = FindQueryTerm(components: [.pattern(.digits()), .text("-"), .pattern(.digits())])
        #expect(term.regularExpressionPattern(escapingText: true) == #"(\d+)-(\d+)"#)
    }

    @Test("a pattern without backreferences goes in as it is")
    func patternWithoutBackreferencesGoesInAsItIs() {
        let term = FindQueryTerm(components: [
            .pattern(.wordBreak(identifier: "break")), .text("a"), .pattern(.tab(identifier: "tab")), .pattern(.wordBreak(identifier: "break")),
        ])
        #expect(term.regularExpressionPattern(escapingText: true) == "\\ba\t\\b")
    }

    @Test("group numbers count the groups the patterns' own expressions open, and those of unescaped text")
    func groupNumbersCountThePatternsOwnGroups() throws {
        let grouped = FindPattern(regularExpression: #"(?=x)(a)(?<name>b)[(]\((?i:c)"#, title: "Grouped", tokenTitle: "G", identifier: "grouped")
        let digits = FindPattern.digits(identifier: "digits")
        let term = FindQueryTerm(components: [.pattern(grouped), .pattern(digits), .pattern(digits)])
        // The grouped token is group 1 with 2 and 3 inside it; the digits are group 4.
        let expression = term.regularExpressionPattern(escapingText: true)
        #expect(expression == #"((?=x)(a)(?<name>b)[(]\((?i:c))(\d+)(?:\4)"#)
        #expect(try NSRegularExpression(pattern: expression).numberOfCaptureGroups == 4)

        let regularExpressionText = FindQueryTerm(components: [.text("(x)"), .pattern(digits), .text(#"\1"#), .pattern(digits)])
        #expect(regularExpressionText.regularExpressionPattern(escapingText: false) == #"(x)(\d+)\1(?:\2)"#)
    }

    @Test("capture groups are counted as ICU counts them", arguments: [
        ("", 0),
        ("(a)(b)", 2),
        ("(?:a)(?=b)(?!c)(?<=d)(?<!e)(?>f)(?i)(?#g)", 0),
        ("(?<name>a)", 1),
        (#"\(a\)[()][^)(][](]"#, 0),
    ])
    func captureGroupCount(expression: String, count: Int) {
        #expect(FindQueryTerm.captureGroupCount(in: expression) == count)
    }

    @Test("each of Xcode's patterns opens the capture groups ICU finds in it", arguments: FindPattern.standardPatterns)
    func standardPatternCaptureGroups(pattern: FindPattern) throws {
        let regularExpression = try NSRegularExpression(pattern: pattern.regularExpression)
        #expect(FindQueryTerm.captureGroupCount(in: pattern.regularExpression) == regularExpression.numberOfCaptureGroups, "\(pattern.title)")
    }

    // MARK: - Components

    @Test("a term leaves out empty text and keeps adjacent text apart")
    func termLeavesOutEmptyText() {
        let term = FindQueryTerm(components: [.text(""), .text("a"), .text("b"), .pattern(.digits()), .text("")])
        #expect(term.components == [.text("a"), .text("b"), .pattern(.digits())])
        #expect(term.plainText == "ab")
        #expect(term.hasPatterns)
        #expect(!FindQueryTerm(text: "x").hasPatterns)
        #expect(FindQueryTerm().components.isEmpty)
        #expect(FindQueryTerm(text: "").components.isEmpty)
    }

    @Test("two patterns are equal when every property is, the identifier included")
    func equality() {
        let token = FindPattern.digits(identifier: "token")
        #expect(FindPattern.digits() != token)
        #expect(token == .digits(identifier: "token"))
        #expect(token.hashValue == FindPattern.digits(identifier: "token").hashValue)
        var definition = token
        definition.identifier = nil
        #expect(definition == .digits())

        let term = FindQueryTerm(components: [.text("a"), .pattern(token)])
        #expect(term == FindQueryTerm(components: [.text("a"), .pattern(.digits(identifier: "token"))]))
        #expect(term != FindQueryTerm(components: [.text("a"), .pattern(.digits())]))
    }

    // MARK: - Property list

    @Test("a term's property list has Xcode's keys, is a valid property list, and reads back equal")
    func propertyListRoundTrip() throws {
        let term = FindQueryTerm(components: [.text("a"), .pattern(.digits(identifier: "digits")), .text("b"), .pattern(.tab())])
        let propertyList = term.propertyListRepresentation
        #expect(PropertyListSerialization.propertyList(propertyList, isValidFor: .binary))
        #expect(FindQueryTerm(propertyListRepresentation: propertyList) == term)

        let digitsPropertyList = try #require(propertyList[1] as? [String: Any])
        #expect(digitsPropertyList["NSFindPatternRegularExpressionKey"] as? String == #"\d+"#)
        #expect(digitsPropertyList["NSFindPatternDisplayStringKey"] as? String == "Digits")
        #expect(digitsPropertyList["NSFindPatternTokenStringKey"] as? String == "#")
        #expect(digitsPropertyList["NSFindPatternTokenUniqueIDKey"] as? String == "digits")
        #expect(digitsPropertyList["NSFindPatternTokenReplacementStringKey"] == nil)
    }

    /// What `-[DVTFindPatternFieldEditor writeSelectionToPasteboard:type:]` writes for "a", Digits: Xcode's keys, its
    /// group numbers included.
    @Test("what Xcode's find field writes to the pasteboard reads, its group numbers ignored")
    func xcodesPropertyListReads() throws {
        let xcodePropertyList: [Any] = [
            "a",
            [
                "NSFindPatternRegularExpressionKey": #"\d+"#,
                "NSFindPatternDisplayStringKey": "Digits",
                "NSFindPatternTokenStringKey": "#",
                "NSFindPatternTokenGroupIDKey": 1,
                "NSFindPatternTokenCaptureGroupIDKey": 1,
                "NSFindPatternTokenAllowsBackreferencesKey": true,
                "NSFindPatternTokenIsNegationKey": false,
                "NSFindPatternTokenUniqueIDKey": "8C1D3F5E-0000-4000-8000-000000000001",
            ] as [String: Any],
        ]
        let term = try #require(FindQueryTerm(propertyListRepresentation: xcodePropertyList))
        #expect(term.components == [.text("a"), .pattern(.digits(identifier: "8C1D3F5E-0000-4000-8000-000000000001"))])
    }

    @Test("a malformed property list does not read; a pattern with nothing but its expression does")
    func malformedPropertyListsDoNotRead() throws {
        #expect(FindQueryTerm(propertyListRepresentation: "a") == nil)
        #expect(FindQueryTerm(propertyListRepresentation: [1]) == nil)
        #expect(FindQueryTerm(propertyListRepresentation: [["NSFindPatternDisplayStringKey": "No Expression"]]) == nil)

        let untitled = try #require(FindQueryTerm(propertyListRepresentation: [["NSFindPatternRegularExpressionKey": "x"]]))
        guard case .pattern(let pattern)? = untitled.components.first else {
            Issue.record("expected a pattern, got \(untitled.components)")
            return
        }
        #expect(pattern.title == "")
        #expect(pattern.tokenTitle == "")
        #expect(!pattern.allowsBackreferences)
    }

    @Test("a stored term keeps every property, and a missing replacement string stays missing")
    func storedTermKeepsEveryProperty() throws {
        let pattern = FindPattern(regularExpression: "x+", title: "Exes", tokenTitle: "X", allowsBackreferences: true, replacementString: "y", isNegation: true, identifier: "identifier")
        let term = FindQueryTerm(components: [.text("a"), .pattern(pattern), .pattern(.digits())])
        let decoded = try JSONDecoder().decode(FindQueryTerm.self, from: JSONEncoder().encode(term))
        #expect(decoded == term)
        #expect(decoded.components[1] == .pattern(pattern))
        guard case .pattern(let digits) = decoded.components[2] else {
            Issue.record("expected a pattern, got \(decoded.components[2])")
            return
        }
        #expect(digits.replacementString == nil)
    }
}
