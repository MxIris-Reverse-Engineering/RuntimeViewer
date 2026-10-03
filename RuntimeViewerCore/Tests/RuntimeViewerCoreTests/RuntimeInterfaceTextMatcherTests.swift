import Foundation
import Semantic
import Testing
@testable import RuntimeViewerCore

/// The text matcher on a hand-built interface: the four match styles, case
/// folding, the scope → semantic-kind mapping, line numbers, ranges and the
/// long-line window. No engine involved.
@Suite("RuntimeInterfaceTextMatcher")
struct RuntimeInterfaceTextMatcherTests {
    private static let object = RuntimeObject(name: "Foo", displayName: "Foo", kind: .objc(.type(.class)), imagePath: "/fixture", children: [])

    /// ```
    /// class Foo {
    ///     var fooBar: Int
    ///     // fooBar comment
    ///     func barFoo()
    /// }
    /// ```
    private static let interface: FrozenSemanticString = SemanticString {
        Keyword("class")
        Standard(" ")
        TypeName(kind: .class, "Foo")
        Standard(" {\n    ")
        Keyword("var")
        Standard(" ")
        Variable("fooBar")
        Standard(": ")
        TypeName(kind: .struct, "Int")
        Standard("\n    ")
        Comment("fooBar comment")
        Standard("\n    ")
        Keyword("func")
        Standard(" ")
        FunctionDeclaration("barFoo")
        Standard("()\n}")
    }.frozen()

    private func matches(_ query: RuntimeInterfaceSearchQuery) throws -> (matches: [RuntimeInterfaceSearchMatch], count: Int) {
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(query)
        var collected: [RuntimeInterfaceSearchMatch] = []
        let count = RuntimeInterfaceTextMatcher.matches(in: Self.interface, object: Self.object, pattern: pattern) { match in
            collected.append(match)
            return true
        }
        return (collected, count)
    }

    @Test("a hit starting inside an excluded range is neither reported nor counted")
    func excludedRanges() throws {
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(RuntimeInterfaceSearchQuery(text: "fooBar"))
        let text = Self.interface.text
        // The comment line, `    // fooBar comment`.
        let commentLine = try #require(text.range(of: "    // fooBar comment"))
        let excludedRange = text.utf8.distance(from: text.startIndex, to: commentLine.lowerBound) ..< text.utf8.distance(from: text.startIndex, to: commentLine.upperBound)
        var collected: [RuntimeInterfaceSearchMatch] = []
        let count = RuntimeInterfaceTextMatcher.matches(in: Self.interface, object: Self.object, pattern: pattern, excludingUTF8Ranges: [excludedRange]) { match in
            collected.append(match)
            return true
        }
        #expect(count == 1)
        #expect(collected.map(\.lineNumber) == [2])
    }

    @Test("containing finds every occurrence with its line, range and kind")
    func containing() throws {
        let result = try matches(RuntimeInterfaceSearchQuery(text: "fooBar"))
        #expect(result.count == 2)
        #expect(result.matches.map(\.lineNumber) == [2, 3])
        #expect(result.matches.map(\.semanticKind) == [.variable, .comment])
        #expect(result.matches[0].lineText == "    var fooBar: Int")
        #expect(result.matches[0].matchRangeInLine == RuntimeTextRange(location: 8, length: 6))
        #expect(result.matches[1].lineText == "    // fooBar comment")
        #expect(result.matches[1].matchRangeInLine == RuntimeTextRange(location: 7, length: 6))
    }

    @Test("scopes map to semantic kinds")
    func scopes() throws {
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "fooBar", scope: .all)).count == 2)
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "fooBar", scope: .excludeComments)).count == 1)
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "fooBar", scope: .commentsOnly)).matches.map(\.lineNumber) == [3])
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "fooBar", scope: .symbolsOnly)).matches.map(\.lineNumber) == [2])
        // A keyword is not a symbol.
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "class", scope: .symbolsOnly)).count == 0)
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "class", scope: .excludeComments)).count == 1)
    }

    @Test("case folding is ASCII and optional")
    func caseFolding() throws {
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "FOOBAR", isCaseSensitive: false)).count == 2)
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "FOOBAR", isCaseSensitive: true)).count == 0)
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "fooBar", isCaseSensitive: true)).count == 2)
    }

    @Test("word-boundary match styles")
    func wordBoundaries() throws {
        // Case-insensitive, `foo` is the whole word `Foo` on line 1 and no other.
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "foo", matchMode: .matchingWord)).matches.map(\.lineNumber) == [1])
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "foo", matchMode: .matchingWord, isCaseSensitive: true)).count == 0)
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "Foo", matchMode: .matchingWord, isCaseSensitive: true)).matches.map(\.lineNumber) == [1])
        // `foo` starts `fooBar` (twice) but not `barFoo`.
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "foo", matchMode: .startingWith, isCaseSensitive: true)).count == 2)
        // `Foo` ends `Foo` and `barFoo`, not `fooBar`.
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "Foo", matchMode: .endingWith, isCaseSensitive: true)).matches.map(\.lineNumber) == [1, 4])
        #expect(try matches(RuntimeInterfaceSearchQuery(text: "Bar", matchMode: .startingWith, isCaseSensitive: true)).count == 0)
    }

    @Test("regular expressions")
    func regularExpressions() throws {
        let result = try matches(RuntimeInterfaceSearchQuery(text: "foo(bar|baz)", matchMode: .regularExpression, isCaseSensitive: false))
        #expect(result.count == 2)
        #expect(result.matches[0].matchRangeInLine == RuntimeTextRange(location: 8, length: 6))
        #expect(throws: RuntimeInterfaceTextMatcher.PatternError.self) {
            try RuntimeInterfaceTextMatcher.Pattern(RuntimeInterfaceSearchQuery(text: "(", matchMode: .regularExpression))
        }
        #expect(throws: RuntimeInterfaceTextMatcher.PatternError.self) {
            try RuntimeInterfaceTextMatcher.Pattern(RuntimeInterfaceSearchQuery(text: ""))
        }
    }

    @Test("counting goes on after collection stops")
    func countingPastCollection() throws {
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(RuntimeInterfaceSearchQuery(text: "fooBar"))
        var collected = 0
        let count = RuntimeInterfaceTextMatcher.matches(in: Self.interface, object: Self.object, pattern: pattern) { _ in
            collected += 1
            return false
        }
        #expect(collected == 1)
        #expect(count == 2)
    }

    @Test("a long line is windowed around the hit")
    func longLineWindow() {
        let padding = String(repeating: "x", count: 900)
        let line = padding + "needle" + String(repeating: "y", count: 300)
        let (text, range) = RuntimeInterfaceTextMatcher.windowed(line: line, location: 900, length: 6)
        #expect(text.utf16.count <= RuntimeInterfaceTextMatcher.lineTextWindowLength + 2)
        #expect(text.hasPrefix("…"))
        #expect(text.hasSuffix("…"))
        let start = text.utf16.index(text.startIndex, offsetBy: range.location)
        let end = text.utf16.index(start, offsetBy: range.length)
        #expect(String(text[start ..< end]) == "needle")

        let short = RuntimeInterfaceTextMatcher.windowed(line: "short line", location: 6, length: 4)
        #expect(short.text == "short line")
        #expect(short.range == RuntimeTextRange(location: 6, length: 4))
    }

    /// One member name, one query, and where the query should land in the
    /// name — `nil` for nowhere.
    struct MemberNameCase: Sendable, CustomTestStringConvertible {
        let name: String
        let query: String
        let matchMode: RuntimeInterfaceSearchMatchMode
        var isCaseSensitive = false
        let expectedRange: RuntimeTextRange?

        var testDescription: String {
            "\(matchMode) \"\(query)\" in \(name)"
        }
    }

    @Test("member names follow the text match styles, each selector piece a word of its own", arguments: [
        MemberNameCase(name: "initWithFrame:", query: "withframe", matchMode: .containing, expectedRange: RuntimeTextRange(location: 4, length: 9)),
        MemberNameCase(name: "initWithFrame:", query: "withframe", matchMode: .containing, isCaseSensitive: true, expectedRange: nil),
        MemberNameCase(name: "tableView:didSelectRowAtIndexPath:", query: "did", matchMode: .startingWith, expectedRange: RuntimeTextRange(location: 10, length: 3)),
        MemberNameCase(name: "tableView:didSelectRowAtIndexPath:", query: "Select", matchMode: .startingWith, expectedRange: nil),
        MemberNameCase(name: "tableView:didSelectRowAtIndexPath:", query: "didSelectRowAtIndexPath", matchMode: .matchingWord, isCaseSensitive: true, expectedRange: RuntimeTextRange(location: 10, length: 23)),
        MemberNameCase(name: "initWithFrame:", query: "Frame", matchMode: .endingWith, isCaseSensitive: true, expectedRange: RuntimeTextRange(location: 8, length: 5)),
        MemberNameCase(name: "initWithFrame:", query: "With", matchMode: .endingWith, isCaseSensitive: true, expectedRange: nil),
        MemberNameCase(name: "delegate", query: "delegate", matchMode: .matchingWord, expectedRange: RuntimeTextRange(location: 0, length: 8)),
        MemberNameCase(name: "setDelegate:", query: "delegate", matchMode: .matchingWord, expectedRange: nil),
        MemberNameCase(name: "_delegate", query: "delegate", matchMode: .matchingWord, expectedRange: nil),
        MemberNameCase(name: "viewDidLoad", query: "load$", matchMode: .regularExpression, expectedRange: RuntimeTextRange(location: 7, length: 4)),
        MemberNameCase(name: "viewDidLoad", query: "^load", matchMode: .regularExpression, expectedRange: nil),
        // `ö` and `ß` are two UTF-8 bytes but one UTF-16 unit each.
        MemberNameCase(name: "größeÄndern", query: "Ändern", matchMode: .containing, isCaseSensitive: true, expectedRange: RuntimeTextRange(location: 5, length: 6)),
    ])
    func memberNameMatchStyles(_ testCase: MemberNameCase) throws {
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(text: testCase.query, matchMode: testCase.matchMode, isCaseSensitive: testCase.isCaseSensitive)
        #expect(RuntimeInterfaceTextMatcher.memberNameMatchRange(in: testCase.name, pattern: pattern) == testCase.expectedRange)
    }
}
