import Foundation
import Testing
@testable import RuntimeViewerApplication

/// `NavigatorTextFilter`: the sidebar's text filter, parsed and compared the way Xcode 27's navigators parse and
/// compare their filter text (`/Volumes/RE/Xcode/27.2/README.md`, "Navigator text filter tokens"), plus the `!x` form
/// for Does Not Contain.
@Suite("NavigatorTextFilter")
struct NavigatorTextFilterTests {
    typealias Term = NavigatorTextFilter.Term

    // MARK: - Parsing

    @Test(
        "typed text parses into Xcode's comparisons",
        arguments: [
            ("loo", [Term(comparison: .contains, value: "loo")]),
            ("loo*", [Term(comparison: .beginsWith, value: "loo")]),
            ("*loo", [Term(comparison: .endsWith, value: "loo")]),
            ("*", [Term(comparison: .endsWith, value: "")]),
            ("a*b", [Term(comparison: .like, value: "a*b")]),
            ("*a*", [Term(comparison: .like, value: "*a*")]),
            ("t?ble", [Term(comparison: .like, value: "t?ble")]),
            ("a\\b", [Term(comparison: .like, value: "a\\b")]),
            ("foo bar", [Term(comparison: .contains, value: "foo"), Term(comparison: .contains, value: "bar")]),
            ("foo\\ bar", [Term(comparison: .contains, value: "foo bar")]),
            ("  foo   ", [Term(comparison: .contains, value: "foo")]),
            ("view\tcontroller", [Term(comparison: .contains, value: "view"), Term(comparison: .contains, value: "controller")]),
            ("!loo", [Term(comparison: .doesNotContain, value: "loo")]),
            ("!", [Term(comparison: .contains, value: "!")]),
            ("!lo*", [Term(comparison: .beginsWith, value: "!lo")]),
            ("NS* !Private", [Term(comparison: .beginsWith, value: "NS"), Term(comparison: .doesNotContain, value: "Private")]),
        ] as [(String, [Term])]
    )
    func parsesTypedText(text: String, expectedTerms: [Term]) {
        #expect(NavigatorTextFilter.terms(parsing: text) == expectedTerms)
    }

    @Test("text with nothing but white space has no term", arguments: ["", " ", "   ", "\t "])
    func whiteSpaceHasNoTerm(text: String) {
        #expect(NavigatorTextFilter.terms(parsing: text).isEmpty)
        #expect(NavigatorTextFilter(typedText: text).isEmpty)
    }

    @Test(
        "a term's editing string parses back into the same term",
        arguments: [
            Term(comparison: .contains, value: "loo"),
            Term(comparison: .contains, value: "foo bar"),
            Term(comparison: .contains, value: "!"),
            Term(comparison: .doesNotContain, value: "loo"),
            Term(comparison: .doesNotContain, value: "foo bar"),
            Term(comparison: .beginsWith, value: "loo"),
            Term(comparison: .endsWith, value: "loo"),
            Term(comparison: .endsWith, value: ""),
            Term(comparison: .like, value: "a*b"),
            Term(comparison: .like, value: "a b*c"),
            Term(comparison: .like, value: "a\\*b"),
        ]
    )
    func editingStringRoundTrips(term: Term) {
        let editingString = NavigatorTextFilter.editingString(for: term)
        #expect(NavigatorTextFilter.terms(parsing: editingString) == [term], "editing string: \(editingString)")
    }

    @Test("the editing strings read the way Xcode writes them, with !x for Does Not Contain")
    func editingStringsReadLikeXcode() {
        #expect(NavigatorTextFilter.editingString(for: Term(comparison: .contains, value: "loo")) == "loo")
        #expect(NavigatorTextFilter.editingString(for: Term(comparison: .beginsWith, value: "loo")) == "loo*")
        #expect(NavigatorTextFilter.editingString(for: Term(comparison: .endsWith, value: "loo")) == "*loo")
        #expect(NavigatorTextFilter.editingString(for: Term(comparison: .doesNotContain, value: "loo")) == "!loo")
        #expect(NavigatorTextFilter.editingString(for: Term(comparison: .contains, value: "foo bar")) == "foo\\ bar")
    }

    @Test("every condition is the tokens' terms followed by the typed text's")
    func allTermsAreTheTokensThenTheTypedText() {
        let filter = NavigatorTextFilter(terms: [Term(comparison: .beginsWith, value: "NS")], typedText: "view !Private")
        #expect(filter.allTerms == [
            Term(comparison: .beginsWith, value: "NS"),
            Term(comparison: .contains, value: "view"),
            Term(comparison: .doesNotContain, value: "Private"),
        ])
        #expect(!filter.isEmpty)
        #expect(NavigatorTextFilter.empty.isEmpty)
    }

    // MARK: - Comparisons

    private func matches(_ comparison: NavigatorTextFilter.Comparison, _ value: String, _ name: String, isCaseSensitive: Bool = false) -> Bool {
        NavigatorTextFilter.CompiledTerm(term: Term(comparison: comparison, value: value), isCaseSensitive: isCaseSensitive).matches(name)
    }

    @Test("Contains ignores case and diacritics, as localizedStandardContains does")
    func containsIgnoresCaseAndDiacritics() {
        #expect(matches(.contains, "view", "NSViewController"))
        #expect(matches(.contains, "cafe", "CaféMenu"))
        #expect(!matches(.contains, "window", "NSViewController"))
    }

    @Test("Does Not Contain is the opposite of Contains")
    func doesNotContainIsTheOppositeOfContains() {
        #expect(matches(.doesNotContain, "window", "NSViewController"))
        #expect(!matches(.doesNotContain, "VIEW", "NSViewController"))
        #expect(!matches(.doesNotContain, "cafe", "CaféMenu"))
    }

    @Test("Begins With and Ends With are anchored and ignore case but not diacritics")
    func beginsAndEndsWithAreAnchored() {
        #expect(matches(.beginsWith, "nsview", "NSViewController"))
        #expect(!matches(.beginsWith, "nsview", "MyNSView"))
        #expect(matches(.endsWith, "CONTROLLER", "NSViewController"))
        #expect(!matches(.endsWith, "controller", "ControllerBox"))
        #expect(!matches(.beginsWith, "ecl", "Éclair"))
        #expect(!matches(.endsWith, "cafe", "MenuCafé"))
    }

    @Test("an empty Ends With — Xcode's lone * — matches no name")
    func emptyEndsWithMatchesNothing() {
        #expect(!matches(.endsWith, "", "NSView"))
        #expect(!matches(.endsWith, "", ""))
    }

    @Test("Like matches its wildcard pattern anywhere in the name, ignoring case")
    func likeMatchesWildcardsAnywhere() {
        #expect(matches(.like, "table*delegate", "NSTableViewDelegate"))
        #expect(matches(.like, "t?ble", "NSTableView"))
        #expect(!matches(.like, "t??ble", "NSTableView"))
        #expect(matches(.like, "a\\*b", "a*b"))
        #expect(!matches(.like, "a\\*b", "axb"))
        #expect(matches(.like, "(*)", "Foo (Bar) Baz"))
    }

    @Test("Match Case makes every comparison tell upper from lower case")
    func matchCaseIsCaseSensitive() {
        #expect(!matches(.contains, "view", "NSViewController", isCaseSensitive: true))
        #expect(matches(.contains, "View", "NSViewController", isCaseSensitive: true))
        #expect(matches(.doesNotContain, "view", "NSViewController", isCaseSensitive: true))
        #expect(!matches(.beginsWith, "ns", "NSView", isCaseSensitive: true))
        #expect(!matches(.endsWith, "view", "NSView", isCaseSensitive: true))
        #expect(!matches(.like, "n?view", "NSView", isCaseSensitive: true))
        #expect(matches(.like, "N?View", "NSView", isCaseSensitive: true))
    }

    @Test("a name passes the filter only when it satisfies every term")
    func everyTermMustHold() {
        let matcher = NavigatorTextFilter(terms: [Term(comparison: .beginsWith, value: "NS")], typedText: "view !controller").makeMatcher()
        #expect(matcher.matches("NSViewStack"))
        #expect(!matcher.matches("NSViewController"))
        #expect(!matcher.matches("UIViewStack"))
        #expect(!matcher.matches("NSWindow"))
    }

    @Test("an empty filter lets every name through")
    func emptyFilterMatchesEverything() {
        let matcher = NavigatorTextFilter.empty.makeMatcher()
        #expect(matcher.isEmpty)
        #expect(matcher.matches("anything"))
        #expect(matcher.matches(""))
    }
}
