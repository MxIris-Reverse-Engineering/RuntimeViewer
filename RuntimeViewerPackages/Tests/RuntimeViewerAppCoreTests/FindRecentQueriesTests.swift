import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The Find navigator's recent queries, kept as Xcode's `IDEFindNavigatorQueryHistoryManager` keeps
/// its own — the latest first, ten at most, a search run again moved up — and titled as Xcode titles
/// them.
@Suite("FindRecentQueries")
struct FindRecentQueriesTests {
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
    func samePatternsTypedAgainMoveUp() {
        let typedFirst = FindQuery(term: FindQueryTerm(components: [.text("v"), .pattern(.digits(identifier: "first"))]))
        let typedAgain = FindQuery(term: FindQueryTerm(components: [.text("v"), .pattern(.digits(identifier: "again"))]))
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
        let digits = FindPattern.digits(identifier: "digits")
        let recentQueries = [
            FindQuery(term: FindQueryTerm(components: [.text("v"), .pattern(digits), .text("."), .pattern(digits)]), isCaseSensitive: true),
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

    // MARK: - A file an earlier version wrote

    /// Tokens as the query field stores them: AppKitPlus's `NSFindPattern` property lists, with the UUID
    /// identifiers the field gives its tokens.
    private static let storedDigits = ##"{"NSFindPatternDisplayStringKey":"Digits","NSFindPatternRegularExpressionKey":"\\d+","NSFindPatternTokenAllowsBackreferencesKey":true,"NSFindPatternTokenIsNegationKey":false,"NSFindPatternTokenStringKey":"#","NSFindPatternTokenUniqueIDKey":"6F1A4D0E-2B7C-4E59-9A3D-0C8B5E7F1A21"}"##
    private static let storedWord = #"{"NSFindPatternDisplayStringKey":"Any Word Characters","NSFindPatternRegularExpressionKey":"\\w+","NSFindPatternTokenAllowsBackreferencesKey":true,"NSFindPatternTokenIsNegationKey":false,"NSFindPatternTokenStringKey":"Word","NSFindPatternTokenUniqueIDKey":"B2E4C6A8-1D3F-4A5B-8C7D-9E0F1A2B3C42"}"#
    private static let storedWordBreak = #"{"NSFindPatternDisplayStringKey":"Word Break","NSFindPatternRegularExpressionKey":"\\b","NSFindPatternTokenAllowsBackreferencesKey":false,"NSFindPatternTokenIsNegationKey":false,"NSFindPatternTokenStringKey":"Break","NSFindPatternTokenUniqueIDKey":"0D9C8B7A-6E5F-4D3C-2B1A-0F9E8D7C6B53"}"#
    private static let storedAnyCharacters = #"{"NSFindPatternDisplayStringKey":"Any Characters","NSFindPatternRegularExpressionKey":".+?","NSFindPatternTokenAllowsBackreferencesKey":true,"NSFindPatternTokenIsNegationKey":false,"NSFindPatternTokenStringKey":"Any","NSFindPatternTokenUniqueIDKey":"3A4B5C6D-7E8F-4091-A2B3-C4D5E6F7A864"}"#
    private static let storedTab = #"{"NSFindPatternDisplayStringKey":"Tab","NSFindPatternRegularExpressionKey":"\t","NSFindPatternTokenAllowsBackreferencesKey":false,"NSFindPatternTokenIsNegationKey":false,"NSFindPatternTokenReplacementStringKey":"\t","NSFindPatternTokenStringKey":"→","NSFindPatternTokenUniqueIDKey":"9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B75"}"#
    private static let storedNonASCII = #"{"NSFindPatternDisplayStringKey":"Non-ASCII Characters","NSFindPatternRegularExpressionKey":"[^\\00-\\x7E]+","NSFindPatternTokenAllowsBackreferencesKey":true,"NSFindPatternTokenIsNegationKey":true,"NSFindPatternTokenStringKey":"ASCII","NSFindPatternTokenUniqueIDKey":"1E2D3C4B-5A69-4788-9A0B-1C2D3E4F5A86"}"#

    /// `findRecentQueriesByScope.json` as the version before the proposal `app-core-ui-split` wrote it, when
    /// `FindQueryTerm` held AppKitPlus's `NSFindPatternComponents`: a backreference, text that is regular expression
    /// syntax with a group of its own, a token without backreferences, a replacement string, a negation, and a query
    /// without patterns.
    private static let storedRecentQueriesFile = [
        #"{"source":["#,
        #"{"isCaseSensitive":true,"memberKindFilter":{"any":{}},"memberMatchStyle":"containing","mode":"text","scope":{"allIndexedImages":{}},"term":["build ","#,
        storedDigits, #",".","#, storedWord, #",".","#, storedDigits,
        #"],"textMatchStyle":"matchingWord"},"#,
        #"{"isCaseSensitive":false,"memberKindFilter":{"any":{}},"memberMatchStyle":"containing","mode":"regularExpression","scope":{"currentImage":{}},"term":["^init","#,
        storedWordBreak, #","(With)?","#, storedAnyCharacters,
        #"],"textMatchStyle":"containing"},"#,
        #"{"isCaseSensitive":false,"memberKindFilter":{"kind":{"_0":"objcMethod"}},"memberMatchStyle":"startingWith","mode":"members","scope":{"images":{"_0":["\/System\/Library\/Frameworks\/AppKit.framework\/AppKit"]}},"term":["set","#,
        storedTab, ",", storedNonASCII,
        #"],"textMatchStyle":"containing"},"#,
        #"{"isCaseSensitive":false,"memberKindFilter":{"any":{}},"memberMatchStyle":"containing","mode":"ancestorTypes","scope":{"allIndexedImages":{}},"term":["NSView"],"textMatchStyle":"endingWith"}"#,
        "]}",
    ].joined()

    @Test("recent queries an earlier version stored read back as the same searches, and are written back byte for byte")
    func recentQueriesAnEarlierVersionStoredReadBack() throws {
        let readingDirectoryURL = AppDefaults.makeTemporaryStorageDirectoryURL(label: "find-recent-queries-stored")
        let writingDirectoryURL = AppDefaults.makeTemporaryStorageDirectoryURL(label: "find-recent-queries-written")
        defer {
            try? FileManager.default.removeItem(at: readingDirectoryURL)
            try? FileManager.default.removeItem(at: writingDirectoryURL)
        }
        try FileManager.default.createDirectory(at: readingDirectoryURL, withIntermediateDirectories: true)
        try Data(Self.storedRecentQueriesFile.utf8).write(to: readingDirectoryURL.appendingPathComponent("findRecentQueriesByScope.json"))

        let readingStore = AppDefaults(storageDirectoryURL: readingDirectoryURL, userDefaultsNamespace: .makeIsolated())
        let recentQueries = try #require(readingStore.findRecentQueriesByScope["source"])
        try #require(recentQueries.count == 4, "a query that does not decode is dropped")

        #expect(recentQueries.map { FindRecentQueries.title(for: $0) } == [
            "In Indexed Images, text matching word “build ..”, match case",
            "In Current Image, regular expression “^init(With)?”, ignore case",
            "In AppKit, ObjC Method members starting with “set”, ignore case",
            "In Indexed Images, ancestor types ending with “NSView”, ignore case",
        ])
        #expect(recentQueries[0].textSearchText == FindSearchText(text: RuntimeTextPattern.regularExpression(#"build (\d+)\.(\w+)\.(?:\1)"#, boundedAs: .matchingWord), matchMode: .regularExpression))
        #expect(recentQueries[1].textSearchText == FindSearchText(text: #"^init\b(With)?(.+?)"#, matchMode: .regularExpression))
        #expect(recentQueries[2].memberSearchText == FindSearchText(text: RuntimeTextPattern.regularExpression("set\t([^\\00-\\x7E]+)", boundedAs: .startingWith), matchMode: .regularExpression))
        #expect(recentQueries[3].relationshipSearchText == FindSearchText(text: "NSView", matchMode: .endingWith))

        let writingStore = AppDefaults(storageDirectoryURL: writingDirectoryURL, userDefaultsNamespace: .makeIsolated())
        writingStore.findRecentQueriesByScope = ["source": recentQueries]
        // A read waits for the write, which puts the file on disk.
        _ = writingStore.findRecentQueriesByScope
        let writtenFile = try String(contentsOf: writingDirectoryURL.appendingPathComponent("findRecentQueriesByScope.json"), encoding: .utf8)
        #expect(writtenFile == Self.storedRecentQueriesFile)
    }
}
