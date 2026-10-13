import AppKit
import AppKitPlus
import Foundation
import Testing
@testable import RuntimeViewerApplication

/// The Find navigator's recent queries, kept as Xcode's `IDEFindNavigatorQueryHistoryManager` keeps
/// its own — the latest first, ten at most, a search run again moved up — and titled as Xcode titles
/// them.
@Suite("FindRecentQueries")
struct FindRecentQueriesTests {
    private static func standardPattern(_ title: String) throws -> NSFindPattern {
        try #require(NSFindPattern.standardPatternGroups.flatMap { $0 }.first { $0.title == title })
    }

    @Test("a query run goes first, the same search moves up instead of repeating, and ten are kept")
    func recording() {
        var recentQueries: [FindQuery] = []
        for index in 0 ..< 12 {
            recentQueries = FindRecentQueries.recording(FindQuery(text: "query \(index)"), in: recentQueries)
        }
        #expect(recentQueries.count == FindRecentQueries.maximumCount)
        #expect(recentQueries.first == FindQuery(text: "query 11"))
        #expect(recentQueries.last == FindQuery(text: "query 2"))

        recentQueries = FindRecentQueries.recording(FindQuery(text: "query 5"), in: recentQueries)
        #expect(recentQueries.count == FindRecentQueries.maximumCount)
        #expect(recentQueries.first == FindQuery(text: "query 5"))
        #expect(recentQueries.filter { $0 == FindQuery(text: "query 5") }.count == 1)

        // Another case, mode or scope is another search.
        recentQueries = FindRecentQueries.recording(FindQuery(text: "query 5", isCaseSensitive: true), in: recentQueries)
        #expect(recentQueries.prefix(2).map(\.isCaseSensitive) == [true, false])

        #expect(FindRecentQueries.recording(FindQuery(text: "  "), in: recentQueries) == recentQueries, "an empty query is not recorded")
    }

    @Test("the same patterns typed again move up, though their tokens carry new identifiers")
    func samePatternsTypedAgainMoveUp() throws {
        let digits = try Self.standardPattern("Digits")
        let typedFirst = FindQuery(term: FindQueryTerm(components: NSFindPatternComponents([.text("v"), .pattern(digits.withIdentifier("first"))])))
        let typedAgain = FindQuery(term: FindQueryTerm(components: NSFindPatternComponents([.text("v"), .pattern(digits.withIdentifier("again"))])))
        var recentQueries = FindRecentQueries.recording(typedFirst, in: [])
        recentQueries = FindRecentQueries.recording(FindQuery(text: "other"), in: recentQueries)
        recentQueries = FindRecentQueries.recording(typedAgain, in: recentQueries)
        #expect(recentQueries == [typedAgain, FindQuery(text: "other")])
    }

    @Test("a title says where, what, the query and the case, as Xcode's does", arguments: [
        (FindQuery(text: "NSView"), "In Indexed Images, text containing “NSView”, ignore case"),
        (FindQuery(text: "View", textMatchStyle: .matchingWord, isCaseSensitive: true, scope: .currentImage), "In Current Image, text matching word “View”, match case"),
        (FindQuery(mode: .regularExpression, text: "^init", textMatchStyle: .endingWith), "In Indexed Images, regular expression “^init”, ignore case"),
        (FindQuery(mode: .ancestorTypes, text: "View", textMatchStyle: .startingWith, scope: .images(["/System/Library/Frameworks/Foundation.framework/Foundation"])), "In Foundation, ancestor types starting with “View”, ignore case"),
        (FindQuery(mode: .descendantTypes, text: "NSObject", scope: .images(["/a/One", "/b/Two"])), "In 2 Images, descendent types containing “NSObject”, ignore case"),
        (FindQuery(mode: .conformingTypes, text: "Sendable", textMatchStyle: .endingWith), "In Indexed Images, conforming types ending with “Sendable”, ignore case"),
        (FindQuery(mode: .members, text: "frame", memberMatchStyle: .matchingWord), "In Indexed Images, members matching word “frame”, ignore case"),
        (FindQuery(mode: .members, text: "^init", memberMatchStyle: .regularExpression, memberKindFilter: .kind(.objcMethod)), "In Indexed Images, ObjC Method members matching regular expression “^init”, ignore case"),
    ])
    func titles(query: FindQuery, title: String) {
        #expect(FindRecentQueries.title(for: query) == title)
    }

    @Test("recent queries outlive the app: a store on the same directory reads them back, patterns included")
    func recentQueriesOutliveTheApp() throws {
        let directoryURL = AppDefaults.makeTemporaryStorageDirectoryURL(label: "find-recent-queries")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let digits = try Self.standardPattern("Digits").withIdentifier("digits")
        let recentQueries = [
            FindQuery(term: FindQueryTerm(components: NSFindPatternComponents([.text("v"), .pattern(digits), .text("."), .pattern(digits)])), isCaseSensitive: true),
            FindQuery(mode: .regularExpression, text: "^init", scope: .currentImage),
        ]
        do {
            let writingStore = AppDefaults(storageDirectoryURL: directoryURL, userDefaultsNamespace: .makeIsolated())
            writingStore.findRecentQueriesByScope = ["source": recentQueries]
            // A read waits for the write, which puts the file on disk.
            #expect(writingStore.findRecentQueriesByScope["source"] == recentQueries)
        }
        let readingStore = AppDefaults(storageDirectoryURL: directoryURL, userDefaultsNamespace: .makeIsolated())
        #expect(readingStore.findRecentQueriesByScope["source"] == recentQueries)
    }

    @Test("the menu's title draws the patterns between the quotes as tokens, in the menu's font")
    @MainActor
    func attributedTitleDrawsTokens() throws {
        let digits = try Self.standardPattern("Digits").withIdentifier("digits")
        let query = FindQuery(term: FindQueryTerm(components: NSFindPatternComponents([.text("build "), .pattern(digits)])))
        let font = NSFont.menuFont(ofSize: 10)
        let attributedTitle = FindRecentQueries.attributedTitle(for: query, font: font)
        #expect(attributedTitle.string == "In Indexed Images, text containing “build \u{FFFC}”, ignore case")
        #expect(FindRecentQueries.title(for: query) == "In Indexed Images, text containing “build ”, ignore case")

        var attachmentCount = 0
        attributedTitle.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedTitle.length)) { attachment, _, _ in
            if attachment != nil { attachmentCount += 1 }
        }
        #expect(attachmentCount == 1)
        #expect(attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == font)
        #expect(attributedTitle.attribute(.font, at: attributedTitle.length - 1, effectiveRange: nil) as? NSFont == font)
    }
}
