import Foundation
import Testing
@testable import RuntimeViewerAppCore

/// How the naming word cloud splits a name into words, finds an image's
/// class prefix and keeps compound words whole.
@Suite("NamingWordTokenizer")
struct NamingWordTokenizerTests {
    @Test(
        "names split at case changes, with acronyms whole and digits kept with the letters before them",
        arguments: [
            ("NSLayoutManager", ["NS", "Layout", "Manager"]),
            ("URLSession", ["URL", "Session"]),
            ("NSURLSession", ["NSURL", "Session"]),
            ("UTF8String", ["UTF8", "String"]),
            ("setNeedsDisplayInRect:", ["set", "Needs", "Display", "In", "Rect"]),
            ("tableView:cellForRowAtIndexPath:", ["table", "View", "cell", "For", "Row", "At", "Index", "Path"]),
            ("_privateStorage_", ["private", "Storage"]),
            ("__lazy_storage_value", ["lazy", "storage", "value"]),
            ("iOSVersion", ["OS", "Version"]),
            // The digit stays with the word before it; the D after it is a single letter.
            ("CGPoint3D", ["CG", "Point3"]),
            ("x", []),
            ("version2", ["version2"]),
            ("Outer.Inner", ["Outer", "Inner"]),
        ]
    )
    func splitting(name: String, expectedWords: [String]) {
        #expect(NamingWordTokenizer.words(in: name) == expectedWords)
    }

    @Test("single letters and digits alone are dropped")
    func droppedWords() {
        #expect(NamingWordTokenizer.words(in: "a_1_ab_12") == ["ab"])
        #expect(NamingWordTokenizer.words(in: "XYPoint") == ["XY", "Point"])
    }

    @Test("common words are dropped only when asked")
    func commonWords() {
        #expect(NamingWordTokenizer.countedWords(in: "initWithFrame:forView:", compoundWords: nil, ignoresCommonWords: true) == ["init", "Frame", "View"])
        #expect(NamingWordTokenizer.countedWords(in: "initWithFrame:forView:", compoundWords: nil, ignoresCommonWords: false) == ["init", "With", "Frame", "for", "View"])
    }

    @Test("compound words are merged before common words are dropped, spelled as their parts were")
    func compoundWords() {
        let compoundWords = NamingCompoundWords(words: ["DataSource", "IndexPath", "PopUp"])
        #expect(NamingWordTokenizer.countedWords(in: "NSTableViewDataSource", compoundWords: compoundWords, ignoresCommonWords: true) == ["NS", "Table", "View", "DataSource"])
        #expect(NamingWordTokenizer.countedWords(in: "tableView:cellForRowAtIndexPath:", compoundWords: compoundWords, ignoresCommonWords: true) == ["table", "View", "cell", "Row", "IndexPath"])
        #expect(NamingWordTokenizer.countedWords(in: "dataSourceForPopUpButton", compoundWords: compoundWords, ignoresCommonWords: true) == ["dataSource", "PopUp", "Button"])
        #expect(NamingWordTokenizer.countedWords(in: "NSTableViewDataSource", compoundWords: nil, ignoresCommonWords: true) == ["NS", "Table", "View", "Data", "Source"])
    }

    @Test("the longest compound word wins, and one word alone is no compound")
    func longestCompoundWins() {
        let compoundWords = NamingCompoundWords(words: ["ViewController", "SplitViewController", "View"])
        #expect(compoundWords.merging(["Split", "View", "Controller"]) == ["SplitViewController"])
        #expect(compoundWords.merging(["Table", "View", "Controller"]) == ["Table", "ViewController"])
        #expect(compoundWords.words == ["ViewController", "SplitViewController", "View"])
    }

    @Test("the presets less the removed ones, plus the added ones, compared without case")
    func effectiveCompoundWords() {
        let effective = NamingCompoundWords.effective(addedWords: ["VisualProvider", "datasource"], removedPresetWords: ["popup"])
        #expect(effective.words.contains("VisualProvider"))
        #expect(!effective.words.contains("PopUp"))
        #expect(effective.words.filter { $0.lowercased() == "datasource" }.count == 1, "an added word the presets have is kept once")
    }

    @Test("an acronym is shown as spelled, any other word capitalized, a method's first word in lowercase")
    func displayedWords() {
        #expect(NamingWordTokenizer.displayedWord("URL", isLowercased: false) == "URL")
        #expect(NamingWordTokenizer.displayedWord("UTF8", isLowercased: false) == "UTF8")
        #expect(NamingWordTokenizer.displayedWord("set", isLowercased: false) == "Set")
        #expect(NamingWordTokenizer.displayedWord("dataSource", isLowercased: false) == "DataSource")
        #expect(NamingWordTokenizer.displayedWord("URL", isLowercased: true) == "url")
    }

    @Test("the class prefix comes from the image's own type names")
    func detectedPrefixes() {
        let appKitNames = ["NSWindow", "NSView", "NSURLSession", "NSURLRequest", "NSButton", "_NSPrivateThing", "NSColor", "Helper"]
        #expect(NamingTypePrefix.detect(in: appKitNames) == "NS")

        let metalNames = ["MTLDevice", "MTLBuffer", "MTLTexture", "MTLHeap", "MTLFence"]
        #expect(NamingTypePrefix.detect(in: metalNames) == "MTL")

        let swiftNames = ["View", "Text", "Button", "Image", "Color"]
        #expect(NamingTypePrefix.detect(in: swiftNames) == nil)
    }

    @Test("the prefix comes off only where a capital follows it")
    func removedPrefix() {
        #expect(NamingTypePrefix.removing("NS", from: "NSURLSession") == "URLSession")
        #expect(NamingTypePrefix.removing("NS", from: "_NSPrivateThing") == "PrivateThing")
        #expect(NamingTypePrefix.removing("NS", from: "NSobjectish") == "NSobjectish")
        #expect(NamingTypePrefix.removing("UI", from: "NSView") == "NSView")
    }
}
