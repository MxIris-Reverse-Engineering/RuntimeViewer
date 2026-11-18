import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore

/// Which names the naming word cloud counts, how often each word is counted,
/// the category it is coloured as, and the files it exports.
@Suite("NamingWordCounter")
struct NamingWordCounterTests {
    private static let imagePath = "/System/Library/Frameworks/Test.framework/Test"

    private static func object(
        _ displayName: String,
        _ kind: RuntimeObjectKind,
        properties: RuntimeObject.Properties = [],
        children: [RuntimeObject] = []
    ) -> RuntimeObject {
        RuntimeObject(name: displayName, displayName: displayName, kind: kind, imagePath: imagePath, children: children, properties: properties)
    }

    private static func member(_ name: String, _ kind: RuntimeMemberKind, isStatic: Bool = false) -> RuntimeObjectMembers.Member {
        RuntimeObjectMembers.Member(name: name, kind: kind, isStatic: isStatic, lineNumber: 1)
    }

    private static let plainConfiguration = NamingWordCounter.Configuration(typePrefix: nil, compoundWords: nil, ignoresCommonWords: true, excludesUnexportedTypes: false)

    private static func counts(_ measure: NamingWordMeasure, types: [RuntimeObject] = [], members: [RuntimeObjectMembers] = [], memberGroup: NamingMemberGroup? = nil, configuration: NamingWordCounter.Configuration = plainConfiguration) -> [String: NamingWordCount] {
        let counts = NamingWordCounter.counts(of: measure, memberGroup: memberGroup, types: types, members: members, configuration: configuration)
        return Dictionary(uniqueKeysWithValues: counts.map { ($0.word, $0) })
    }

    // MARK: - Types

    @Test("Type Suffixes counts the types ending in each word, prefix removed and compound words kept whole")
    func typeSuffixes() {
        let types = [
            Self.object("NSLayoutManager", .objc(.type(.class))),
            Self.object("NSFontManager", .objc(.type(.class))),
            Self.object("NSWindowController", .objc(.type(.class))),
            Self.object("NSTableViewDataSource", .objc(.type(.protocol))),
            Self.object("NSManager", .objc(.type(.class))),
        ]
        var configuration = Self.plainConfiguration
        configuration.typePrefix = "NS"
        configuration.compoundWords = NamingCompoundWords(words: ["DataSource"])

        let counts = Self.counts(.typeSuffixes, types: types, configuration: configuration)

        #expect(counts["Manager"]?.count == 3)
        #expect(counts["Controller"]?.count == 1)
        #expect(counts["DataSource"]?.count == 1)
        #expect(counts["Source"] == nil)
        #expect(counts["NS"] == nil, "the prefix came off before splitting")
        #expect(counts["Manager"]?.usages.map(\.name) == ["NSFontManager", "NSLayoutManager", "NSManager"])
    }

    @Test("Type Words counts each word once per type holding it")
    func typeWords() {
        let types = [
            Self.object("ViewView", .swift(.type(.class))),
            Self.object("ViewController", .swift(.type(.class))),
        ]
        let split = Self.counts(.typeWords, types: types)
        #expect(split["View"]?.count == 2)
        #expect(split["Controller"]?.count == 1)

        var configuration = Self.plainConfiguration
        configuration.compoundWords = NamingCompoundWords(words: ["ViewController"])
        let merged = Self.counts(.typeWords, types: types, configuration: configuration)
        #expect(merged["View"]?.count == 1)
        #expect(merged["ViewController"]?.count == 1)
    }

    @Test("a nested type counts by its own name, without its generic parameters")
    func nestedTypes() {
        let inner = Self.object("Outer.InnerBox<Element>", .swift(.type(.struct)))
        let outer = Self.object("Outer", .swift(.type(.struct)), children: [inner])

        let counts = Self.counts(.typeWords, types: [outer])

        #expect(counts["Outer"]?.count == 1, "only the outer type holds Outer")
        #expect(counts["Inner"]?.count == 1)
        #expect(counts["Box"]?.count == 1)
        #expect(counts["Element"] == nil)
    }

    @Test("categories, extensions, conformances, the Objective-C face of a Swift type, specialized and local types are not counted")
    func typesLeftOut() {
        let types = [
            Self.object("AlphaWidget", .objc(.type(.class))),
            Self.object("BetaWidget", .objc(.category(.class))),
            Self.object("GammaWidget", .swift(.extension(.struct))),
            Self.object("DeltaWidget", .swift(.conformance(.class))),
            Self.object("EpsilonWidget", .objc(.type(.class)), properties: .isSwiftClass),
            Self.object("ZetaWidget", .objc(.type(.protocol)), properties: .isSwiftProtocol),
            Self.object("EtaWidget", .swift(.type(.struct)), properties: .isSpecialized),
            Self.object("ThetaWidget", .swift(.type(.struct)), properties: .isLocalType),
            Self.object("IotaWidget", .swift(.type(.class)), properties: .isSwiftClass),
        ]

        let counts = Self.counts(.typeSuffixes, types: types)

        #expect(counts["Widget"]?.usages.map(\.name) == ["AlphaWidget", "IotaWidget"])
    }

    @Test("types marked Not Exported are left out only when asked")
    func unexportedTypes() {
        let types = [
            Self.object("PublicThing", .objc(.type(.class))),
            Self.object("HiddenThing", .objc(.type(.class)), properties: .isNotExported),
        ]
        #expect(Self.counts(.typeSuffixes, types: types)["Thing"]?.count == 2)

        var configuration = Self.plainConfiguration
        configuration.excludesUnexportedTypes = true
        #expect(Self.counts(.typeSuffixes, types: types, configuration: configuration)["Thing"]?.count == 1)
    }

    // MARK: - Members

    @Test("a member is counted once per entry, whatever its case or leading underscores, in its group")
    func memberDeduplication() {
        let owner = Self.object("Container", .swift(.type(.struct)))
        let listing = [RuntimeObjectMembers(object: owner, members: [
            Self.member("insert", .swiftFunction),
            Self.member("insert", .swiftFunction),
            Self.member("_name", .swiftField),
            Self.member("name", .swiftVariable),
            Self.member("Name", .swiftEnumCase),
        ])]

        let counts = Self.counts(.memberWords, members: listing)

        #expect(counts["Insert"]?.count == 1)
        #expect(counts["Name"]?.count == 2, "the property and its storage once, the enum case again")
    }

    @Test("nameless and compiler-made members, and the NSObject protocol's four properties, are not counted")
    func membersLeftOut() {
        let owner = Self.object("Widget", .objc(.type(.class)))
        let swiftOwner = Self.object("SwiftWidget", .swift(.type(.class)))
        let listing = [
            RuntimeObjectMembers(object: owner, members: [
                Self.member("description", .objcProperty),
                Self.member("debugDescription", .objcProperty),
                Self.member("hash", .objcProperty),
                Self.member("superclass", .objcProperty),
                Self.member("description", .objcMethod),
                Self.member("frameRect", .objcProperty),
            ]),
            RuntimeObjectMembers(object: swiftOwner, members: [
                Self.member("init", .swiftInitializer),
                Self.member("subscript", .swiftSubscript),
                Self.member("$__lazy_storage_$_cache", .swiftField),
            ]),
        ]

        let counts = Self.counts(.memberWords, members: listing)

        #expect(Set(counts.keys) == ["Description", "Frame", "Rect"])
        #expect(counts["Description"]?.usages.count == 1, "the method, not the property")
    }

    @Test("members of the Objective-C face of a Swift class are not counted twice")
    func memberFacesLeftOut() {
        let swiftClass = Self.object("Widget", .swift(.type(.class)))
        let objcFace = Self.object("Widget", .objc(.type(.class)), properties: .isSwiftClass)
        let listing = [
            RuntimeObjectMembers(object: swiftClass, members: [Self.member("reload", .swiftFunction)]),
            RuntimeObjectMembers(object: objcFace, members: [Self.member("reload", .objcMethod)]),
        ]

        #expect(Self.counts(.memberWords, members: listing)["Reload"]?.count == 1)
    }

    @Test("Member Words can be limited to one group")
    func memberGroups() {
        let owner = Self.object("Widget", .objc(.type(.class)))
        let listing = [RuntimeObjectMembers(object: owner, members: [
            Self.member("frameSize", .objcProperty),
            Self.member("setFrameOrigin:", .objcMethod),
            Self.member("_frameCache", .objcIvar),
        ])]

        #expect(Self.counts(.memberWords, members: listing)["Frame"]?.count == 3)
        #expect(Self.counts(.memberWords, members: listing, memberGroup: .methods)["Frame"]?.count == 1)
        #expect(Self.counts(.memberWords, members: listing, memberGroup: .instanceVariables)["Cache"]?.count == 1)
        #expect(Self.counts(.memberWords, members: listing, memberGroup: .enumCases).isEmpty)
    }

    @Test("Method First Words counts the first word of each method, in lowercase, coloured instance or class method")
    func methodFirstWords() {
        let owner = Self.object("Widget", .objc(.type(.class)))
        let listing = [RuntimeObjectMembers(object: owner, members: [
            Self.member("setFrame:", .objcMethod),
            Self.member("setNeedsDisplay:", .objcMethod),
            Self.member("setTitle:", .objcMethod),
            Self.member("defaultCenter", .objcMethod, isStatic: true),
            Self.member("defaultManager", .objcMethod, isStatic: true),
            Self.member("defaultQueue", .objcMethod, isStatic: true),
            Self.member("frameSize", .objcProperty),
        ])]

        let counts = Self.counts(.methodFirstWords, members: listing)

        #expect(Set(counts.keys) == ["set", "default"])
        #expect(counts["set"]?.count == 3)
        #expect(counts["set"]?.category == .instanceMethod)
        #expect(counts["default"]?.category == .classMethod)
    }

    // MARK: - Order, spelling and colour

    @Test("words are listed the most common first, then alphabetically; names public first")
    func ordering() {
        let types = [
            Self.object("_PrivateLabel", .objc(.type(.class))),
            Self.object("BoxLabel", .objc(.type(.class))),
            Self.object("AlphaButton", .objc(.type(.class))),
            Self.object("CircleButton", .objc(.type(.class))),
            Self.object("ZoneLabel", .objc(.type(.class))),
            Self.object("Field", .objc(.type(.class))),
            Self.object("Cell", .objc(.type(.class))),
        ]

        let counts = NamingWordCounter.counts(of: .typeSuffixes, memberGroup: nil, types: types, members: [], configuration: Self.plainConfiguration)

        #expect(counts.map(\.word) == ["Label", "Button", "Cell", "Field"])
        #expect(counts[0].usages.map(\.name) == ["BoxLabel", "ZoneLabel", "_PrivateLabel"])
    }

    @Test("a word is shown in its most common spelling")
    func spelling() {
        let owner = Self.object("Widget", .objc(.type(.class)))
        let listing = [RuntimeObjectMembers(object: owner, members: [
            Self.member("URLForResource:", .objcMethod),
            Self.member("baseURL", .objcProperty),
            Self.member("urlString", .objcProperty),
        ])]

        #expect(Self.counts(.memberWords, members: listing)["URL"]?.count == 3)
    }

    @Test("a word is coloured as the category it is most representative of, not the one most of its names belong to")
    func representativeCategory() {
        let shares: [NamingWordCategory: Double] = [.property: 0.2, .method: 0.7, .otherMember: 0.1]
        let categories: [NamingWordCategory] = [.property, .method, .otherMember]

        // Half its names are properties, against a fifth of all names.
        #expect(NamingWordCounter.representativeCategory(countsByCategory: [.property: 5, .method: 5], wordTotal: 10, categoryShares: shares, categories: categories) == .property)
        // Mostly methods, as methods are overall.
        #expect(NamingWordCounter.representativeCategory(countsByCategory: [.property: 1, .method: 9], wordTotal: 10, categoryShares: shares, categories: categories) == .method)
        // Fewer than three names in every category: the majority decides.
        #expect(NamingWordCounter.representativeCategory(countsByCategory: [.property: 1, .otherMember: 2], wordTotal: 3, categoryShares: shares, categories: categories) == .otherMember)
    }

    // MARK: - Export

    @Test("CSV lists every word with its count, quoting a field that needs it")
    func csv() {
        let owner = Self.object("Widget", .objc(.type(.class)))
        let counts = [
            NamingWordCount(key: "frame", word: "Frame", category: .property, usages: [.type(owner), .type(owner)]),
            NamingWordCount(key: "a,b", word: "A,\"B\"", category: .method, usages: [.type(owner)]),
        ]

        #expect(NamingWordCountsExport.csv(of: counts) == "word,count\nFrame,2\n\"A,\"\"B\"\"\",1\n")
    }

    @Test("JSON records what the counts were made from, and each word with its names, in the order given")
    func json() throws {
        let owner = Self.object("NSWidget", .objc(.type(.class)))
        let counts = [
            NamingWordCount(key: "widget", word: "Widget", category: .class, usages: [.type(owner)]),
            NamingWordCount(key: "frame", word: "Frame", category: .property, usages: [.member(Self.member("frame", .objcProperty), of: owner)]),
        ]
        let context = NamingWordCountsExport.Context(imagePath: Self.imagePath, measure: .memberWords, memberGroup: .properties, removedTypePrefix: "NS", ignoresCommonWords: true, mergesCompoundWords: false)

        let data = try NamingWordCountsExport.json(of: counts, context: context)
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(document["image"] as? String == "Test")
        #expect(document["measure"] as? String == "memberWords")
        #expect(document["memberGroup"] as? String == "properties")
        #expect(document["removedTypePrefix"] as? String == "NS")
        #expect(document["mergesCompoundWords"] as? Bool == false)
        let words = try #require(document["words"] as? [[String: Any]])
        #expect(words.map { $0["word"] as? String } == ["Widget", "Frame"])
        let typeName = try #require((words[0]["names"] as? [[String: Any]])?.first)
        #expect(typeName["name"] as? String == "NSWidget")
        #expect(typeName["kind"] as? String == "class")
        #expect(typeName["type"] == nil)
        let memberName = try #require((words[1]["names"] as? [[String: Any]])?.first)
        #expect(memberName["name"] as? String == "frame")
        #expect(memberName["kind"] as? String == "property")
        #expect(memberName["type"] as? String == "NSWidget")
    }
}
