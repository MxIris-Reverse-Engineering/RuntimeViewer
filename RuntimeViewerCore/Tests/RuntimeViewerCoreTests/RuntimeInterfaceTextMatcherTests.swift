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
        var budget = RuntimeInterfaceTextMatcher.RegularExpressionBudget()
        var collected: [RuntimeInterfaceSearchMatch] = []
        let count = try RuntimeInterfaceTextMatcher.matches(in: Self.interface, object: Self.object, pattern: pattern, budget: &budget) { match in
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
        var budget = RuntimeInterfaceTextMatcher.RegularExpressionBudget()
        var collected: [RuntimeInterfaceSearchMatch] = []
        let count = try RuntimeInterfaceTextMatcher.matches(in: Self.interface, object: Self.object, pattern: pattern, budget: &budget, excludingUTF8Ranges: [excludedRange]) { match in
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

    /// An entry is a whole multi-line interface while a hit is reported on
    /// its line, so `^` and `$` have to anchor at lines — as they do in
    /// Xcode's Find — or a search for a declaration's shape finds nothing.
    @Test("^ and $ anchor at the lines of a multi-line interface")
    func regularExpressionAnchorsMatchLines() throws {
        let variableLines = try matches(RuntimeInterfaceSearchQuery(text: #"^\s+var\s"#, matchMode: .regularExpression, isCaseSensitive: true))
        #expect(variableLines.count == 1)
        #expect(variableLines.matches.first?.lineNumber == 2)

        let functionLineEnds = try matches(RuntimeInterfaceSearchQuery(text: #"\(\)$"#, matchMode: .regularExpression, isCaseSensitive: true))
        #expect(functionLineEnds.count == 1)
        #expect(functionLineEnds.matches.first?.lineNumber == 4)
    }

    @Test("an invalid regular expression is reported in words on every path an error travels")
    func invalidRegularExpressionReadsAsText() {
        let error = #expect(throws: RuntimeInterfaceTextMatcher.PatternError.self) {
            try RuntimeInterfaceTextMatcher.Pattern(RuntimeInterfaceSearchQuery(text: "(", matchMode: .regularExpression))
        }
        // What the Find navigator shows, and what the XPC transport carries.
        #expect(error?.localizedDescription == "“(” is not a valid regular expression.")
        // What the socket transports carry.
        #expect(error.map { patternError in "\(patternError)" } == "“(” is not a valid regular expression.")
    }

    /// `(a+)+\(` tries every way of splitting a run of a's before it accepts
    /// that no `(` follows, so over a long run one single match never ends on
    /// its own. The budget has to stop it from inside that match.
    @Test("a regular expression that spends its budget stops inside a single match")
    func regularExpressionBudgetStopsOneMatch() throws {
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(text: #"(a+)+\("#, matchMode: .regularExpression, isCaseSensitive: true)
        let run = String(repeating: "a", count: 24)
        let tooExpensive = RuntimeInterfaceTextMatcher.PatternError.regularExpressionTooExpensive(pattern: #"(a+)+\("#)

        var textBudget = RuntimeInterfaceTextMatcher.RegularExpressionBudget(timeLimit: 0.02)
        #expect(throws: tooExpensive) {
            try RuntimeInterfaceTextMatcher.hits(in: "var \(run): Int", pattern: pattern, budget: &textBudget)
        }
        var nameBudget = RuntimeInterfaceTextMatcher.RegularExpressionBudget(timeLimit: 0.02)
        #expect(throws: tooExpensive) {
            try RuntimeInterfaceTextMatcher.memberNameMatchRange(in: run, pattern: pattern, budget: &nameBudget)
        }
        // What every path an error travels shows.
        #expect(tooExpensive.localizedDescription == #"“(a+)+\(” takes too long to match. Nested repetition such as (\w+)+ is the usual cause."#)
        #expect("\(tooExpensive)" == tooExpensive.localizedDescription)
    }

    /// The same stop for a cancelled task. Nothing looks at the task before
    /// the match begins, so a match started by a task already cancelled shows
    /// whether the check inside the match works: without it, the match runs
    /// its full second and returns no hits.
    @Test("a regular expression stops inside a single match once its task is cancelled")
    func regularExpressionStopsOneMatchWhenCancelled() async throws {
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(text: #"(a+)+\("#, matchMode: .regularExpression, isCaseSensitive: true)
        let text = "var " + String(repeating: "a", count: 24) + ": Int"
        let match = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            var budget = RuntimeInterfaceTextMatcher.RegularExpressionBudget()
            return try RuntimeInterfaceTextMatcher.hits(in: text, pattern: pattern, budget: &budget)
        }

        await #expect(throws: CancellationError.self) { try await match.value }
    }

    /// One regular expression and whether a quantifier applies to a group
    /// of it.
    struct QuantifiedGroupCase: Sendable, CustomTestStringConvertible {
        let pattern: String
        let hasQuantifiedGroup: Bool

        var testDescription: String {
            "\(pattern) \(hasQuantifiedGroup ? "has" : "has no") quantified group"
        }
    }

    /// Progress reports cost a call per position scanned, so only the
    /// patterns that can backtrack exponentially get them.
    @Test("only a pattern with a quantified group reports progress while it matches", arguments: [
        QuantifiedGroupCase(pattern: #"(a+)+\("#, hasQuantifiedGroup: true),
        QuantifiedGroupCase(pattern: #"(?:ab)*c"#, hasQuantifiedGroup: true),
        QuantifiedGroupCase(pattern: #"(x|y){2,}"#, hasQuantifiedGroup: true),
        QuantifiedGroupCase(pattern: #"(NS)?String"#, hasQuantifiedGroup: true),
        // An escaped backslash, then a group.
        QuantifiedGroupCase(pattern: #"\\(a)+"#, hasQuantifiedGroup: true),
        // Free spacing: the quantifier stands apart from its group.
        QuantifiedGroupCase(pattern: #"(?x)(a+) +"#, hasQuantifiedGroup: true),
        QuantifiedGroupCase(pattern: #"init\("#, hasQuantifiedGroup: false),
        QuantifiedGroupCase(pattern: #"\bNSString\b"#, hasQuantifiedGroup: false),
        QuantifiedGroupCase(pattern: #"^\s+func\s+\w+\("#, hasQuantifiedGroup: false),
        QuantifiedGroupCase(pattern: #"@property\s*\([^)]*copy"#, hasQuantifiedGroup: false),
        // Groups, none of them quantified.
        QuantifiedGroupCase(pattern: #"(\w+)\s*:\s*(\w+)"#, hasQuantifiedGroup: false),
        // Escaped parentheses, parentheses in a set, in nested sets, quoted.
        QuantifiedGroupCase(pattern: #"\(a\)+"#, hasQuantifiedGroup: false),
        QuantifiedGroupCase(pattern: #"[()]+"#, hasQuantifiedGroup: false),
        QuantifiedGroupCase(pattern: #"[[a-z]&&[^)]]+"#, hasQuantifiedGroup: false),
        QuantifiedGroupCase(pattern: #"\Q(a)+\E"#, hasQuantifiedGroup: false),
        QuantifiedGroupCase(pattern: #"(?i)abc"#, hasQuantifiedGroup: false),
    ])
    func quantifiedGroups(_ testCase: QuantifiedGroupCase) throws {
        #expect(RuntimeInterfaceTextMatcher.hasQuantifiedGroup(testCase.pattern) == testCase.hasQuantifiedGroup)
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(text: testCase.pattern, matchMode: .regularExpression, isCaseSensitive: true)
        #expect(pattern.reportsProgressWhileMatching == testCase.hasQuantifiedGroup)
    }

    @Test("counting goes on after collection stops")
    func countingPastCollection() throws {
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(RuntimeInterfaceSearchQuery(text: "fooBar"))
        var budget = RuntimeInterfaceTextMatcher.RegularExpressionBudget()
        var collected = 0
        let count = try RuntimeInterfaceTextMatcher.matches(in: Self.interface, object: Self.object, pattern: pattern, budget: &budget) { _ in
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
        var budget = RuntimeInterfaceTextMatcher.RegularExpressionBudget()
        #expect(try RuntimeInterfaceTextMatcher.memberNameMatchRange(in: testCase.name, pattern: pattern, budget: &budget) == testCase.expectedRange)
    }

    /// One qualified type name, one query, and whether the query finds the
    /// type.
    struct TypeNameCase: Sendable, CustomTestStringConvertible {
        let name: String
        let query: String
        let matchMode: RuntimeInterfaceSearchMatchMode
        var isCaseSensitive = false
        let matches: Bool

        var testDescription: String {
            "\(matchMode) \"\(query)\" \(matches ? "finds" : "misses") \(name)"
        }
    }

    @Test("type names follow the text match styles on the type's own name, or on the qualified name for a query with a dot", arguments: [
        TypeNameCase(name: "NSMutableString", query: "NSMutable", matchMode: .startingWith, matches: true),
        TypeNameCase(name: "NSMutableString", query: "Mutable", matchMode: .startingWith, matches: false),
        TypeNameCase(name: "NSMutableString", query: "String", matchMode: .endingWith, matches: true),
        TypeNameCase(name: "NSMutableString", query: "Mutable", matchMode: .endingWith, matches: false),
        TypeNameCase(name: "NSMutableString", query: "NSString", matchMode: .matchingWord, matches: false),
        TypeNameCase(name: "NSString", query: "nsstring", matchMode: .matchingWord, matches: true),
        TypeNameCase(name: "NSString", query: "nsstring", matchMode: .matchingWord, isCaseSensitive: true, matches: false),
        TypeNameCase(name: "SwiftUI.View", query: "View", matchMode: .matchingWord, matches: true),
        TypeNameCase(name: "SwiftUI.ViewBuilder", query: "View", matchMode: .startingWith, matches: true),
        // The module and enclosing types are not the type's name.
        TypeNameCase(name: "SwiftUI.View", query: "Swift", matchMode: .startingWith, matches: false),
        TypeNameCase(name: "SwiftUI.View", query: "UI", matchMode: .containing, matches: false),
        TypeNameCase(name: "SwiftUI.Text.Storage", query: "Text", matchMode: .matchingWord, matches: false),
        // A dot names the container, so the qualified name is matched.
        TypeNameCase(name: "SwiftUI.Text.Storage", query: "Text.Storage", matchMode: .matchingWord, matches: true),
        TypeNameCase(name: "SwiftUI.Text.Storage", query: "SwiftUI.Te", matchMode: .startingWith, matches: true),
        // Generic arguments are not the type's name either, and a function
        // type's arrow closes none of their brackets.
        TypeNameCase(name: "Swift.Array<Swift.Int>", query: "Array", matchMode: .matchingWord, matches: true),
        TypeNameCase(name: "Swift.Array<Swift.Int>", query: "Int", matchMode: .containing, matches: false),
        TypeNameCase(name: "Swift.Dictionary<Swift.String, (Swift.Int) -> Swift.Void>", query: "Dictionary", matchMode: .matchingWord, matches: true),
        TypeNameCase(name: "Swift.Dictionary<Swift.String, (Swift.Int) -> Swift.Void>", query: "Void", matchMode: .containing, matches: false),
        // A regular expression anchors itself, so it reads the qualified name.
        TypeNameCase(name: "SwiftUI.View", query: "^SwiftUI\\.V", matchMode: .regularExpression, matches: true),
    ])
    func typeNameMatchStyles(_ testCase: TypeNameCase) throws {
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(text: testCase.query, matchMode: testCase.matchMode, isCaseSensitive: testCase.isCaseSensitive)
        var budget = RuntimeInterfaceTextMatcher.RegularExpressionBudget()
        #expect(try RuntimeInterfaceTextMatcher.typeNameMatches(testCase.name, pattern: pattern, budget: &budget) == testCase.matches)
    }
}
