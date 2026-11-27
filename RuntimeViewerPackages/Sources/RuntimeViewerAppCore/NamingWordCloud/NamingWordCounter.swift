import Foundation
import RuntimeViewerCore

/// Counts the words of an image's names for the naming word cloud: which
/// names are counted, the words each is counted under, how many names hold
/// each word, and the category each word is coloured as.
///
/// Pure and synchronous: the window counts off the main thread, again for
/// every change of measure, switch or Generation Options.
public enum NamingWordCounter {
    /// How names are split before they are counted.
    public struct Configuration: Hashable, Sendable {
        /// The class prefix to take off type names first, or `nil` to keep it.
        public var typePrefix: String?

        /// The compound words to keep whole, or `nil` to split them.
        public var compoundWords: NamingCompoundWords?

        public var ignoresCommonWords: Bool

        /// Leave out the types the sidebar marks Not Exported, as Print
        /// Exported Declarations Only does for the content pane.
        public var excludesUnexportedTypes: Bool

        public init(typePrefix: String?, compoundWords: NamingCompoundWords?, ignoresCommonWords: Bool, excludesUnexportedTypes: Bool) {
            self.typePrefix = typePrefix
            self.compoundWords = compoundWords
            self.ignoresCommonWords = ignoresCommonWords
            self.excludesUnexportedTypes = excludesUnexportedTypes
        }
    }

    /// The words of `measure` in the names of `types` — an image's object
    /// list, nested types in `children` — or of `members` — its corpus, entry
    /// by entry — the most common first, words held by as many names in
    /// alphabetical order. `memberGroup` limits Member Words to one group.
    public static func counts(
        of measure: NamingWordMeasure,
        memberGroup: NamingMemberGroup?,
        types: [RuntimeObject],
        members: [RuntimeObjectMembers],
        configuration: Configuration
    ) -> [NamingWordCount] {
        var countedNames: [CountedName] = []
        switch measure {
        case .typeSuffixes, .typeWords:
            for object in countedTypes(in: types, excludesUnexportedTypes: configuration.excludesUnexportedTypes) {
                var name = typeName(of: object)
                if let typePrefix = configuration.typePrefix {
                    name = NamingTypePrefix.removing(typePrefix, from: name)
                }
                let words = NamingWordTokenizer.countedWords(in: name, compoundWords: configuration.compoundWords, ignoresCommonWords: configuration.ignoresCommonWords)
                countedNames.append(CountedName(
                    usage: .type(object),
                    category: typeCategory(of: object.kind),
                    words: measure == .typeSuffixes ? Array(words.suffix(1)) : words
                ))
            }
        case .memberWords:
            for (member, object) in countedMembers(in: members, group: memberGroup) {
                guard let group = NamingMemberGroup(member.kind) else { continue }
                let words = NamingWordTokenizer.countedWords(in: member.name, compoundWords: configuration.compoundWords, ignoresCommonWords: configuration.ignoresCommonWords)
                countedNames.append(CountedName(usage: .member(member, of: object), category: memberCategory(of: group), words: words))
            }
        case .methodFirstWords:
            for (member, object) in countedMembers(in: members, group: .methods) {
                let words = NamingWordTokenizer.countedWords(in: member.name, compoundWords: configuration.compoundWords, ignoresCommonWords: configuration.ignoresCommonWords)
                countedNames.append(CountedName(
                    usage: .member(member, of: object),
                    category: member.isStatic ? .classMethod : .instanceMethod,
                    words: Array(words.prefix(1))
                ))
            }
        }
        return aggregate(countedNames, categories: measure.categories, lowercasesWords: measure == .methodFirstWords)
    }

    // MARK: - Which names count

    /// The types the cloud counts: Objective-C classes and protocols, Swift
    /// enums, structs, classes, protocols and type aliases, C structs and
    /// unions, nested ones included. Categories, extensions and conformance
    /// entries are not new types. The Objective-C face of a Swift class or a
    /// Swift-defined `@objc` protocol is the same type again, and specialized
    /// and local types are not the image's own names; all three are left out.
    public static func countedTypes(in objects: [RuntimeObject], excludesUnexportedTypes: Bool) -> [RuntimeObject] {
        var countedTypes: [RuntimeObject] = []
        var seenKeys: Set<RuntimeObjectKey> = []
        func visit(_ object: RuntimeObject) {
            if isCountedType(object, excludesUnexportedTypes: excludesUnexportedTypes), !seenKeys.contains(object.key) {
                seenKeys.insert(object.key)
                countedTypes.append(object)
            }
            object.children.forEach(visit)
        }
        objects.forEach(visit)
        return countedTypes
    }

    /// The members the cloud counts, with the object listing each, `group`
    /// alone when it is given. Within one entry of the corpus a member of
    /// the same group and name — ignoring case and leading underscores — is
    /// counted once: the corpus keeps only the base name of a Swift function,
    /// so `insert(_:at:)` and `insert(contentsOf:at:)` are one name, and a
    /// Swift property's storage `_name` is its property `name`. Left out:
    /// Swift initializers and subscripts, which have no name of their own;
    /// storage the compiler makes (`$__lazy_storage_$_name`); the four
    /// properties every class adopting the NSObject protocol carries, which
    /// are not the class's own names; and the entries of the same types
    /// `countedTypes(in:excludesUnexportedTypes:)` leaves out.
    public static func countedMembers(in listing: [RuntimeObjectMembers], group: NamingMemberGroup?) -> [(member: RuntimeObjectMembers.Member, object: RuntimeObject)] {
        var countedMembers: [(member: RuntimeObjectMembers.Member, object: RuntimeObject)] = []
        for objectMembers in listing where !isLeftOut(objectMembers.object) {
            var seenNames: Set<MemberIdentity> = []
            for member in objectMembers.members {
                guard let memberGroup = NamingMemberGroup(member.kind),
                      group == nil || group == memberGroup,
                      !member.name.isEmpty,
                      !member.name.hasPrefix("$"),
                      !(member.kind == .objcProperty && nsObjectProtocolPropertyNames.contains(member.name))
                else { continue }
                let identity = MemberIdentity(group: memberGroup, name: member.name.drop { $0 == "_" }.lowercased())
                guard !seenNames.contains(identity) else { continue }
                seenNames.insert(identity)
                countedMembers.append((member, objectMembers.object))
            }
        }
        return countedMembers
    }

    /// The properties the NSObject protocol declares, which every class that
    /// adopts a protocol refining it carries.
    static let nsObjectProtocolPropertyNames: Set<String> = ["hash", "superclass", "description", "debugDescription"]

    /// A type's own name: without its enclosing types and its generic
    /// parameters (`Outer.Inner<Element>` → `Inner`).
    public static func typeName(of object: RuntimeObject) -> String {
        var name = Substring(object.displayName)
        if let genericStart = name.firstIndex(of: "<") {
            name = name[..<genericStart]
        }
        if let lastDot = name.lastIndex(of: ".") {
            name = name[name.index(after: lastDot)...]
        }
        return String(name)
    }

    /// `class`, `protocol`, `enum`, `struct`, `typealias`, `union`,
    /// `namespace` or `template`.
    public static func kindName(of kind: RuntimeObjectKind) -> String {
        switch kind {
        case .c(.struct): "struct"
        case .c(.union): "union"
        case .cPlusPlus(.class): "class"
        case .cPlusPlus(.classTemplate): "template"
        case .cPlusPlus(.namespace): "namespace"
        case .objc(.type(.class)), .objc(.category(.class)): "class"
        case .objc(.type(.protocol)), .objc(.category(.protocol)): "protocol"
        case .swift(.type(let swiftKind)), .swift(.extension(let swiftKind)), .swift(.conformance(let swiftKind)):
            switch swiftKind {
            case .enum: "enum"
            case .struct: "struct"
            case .class: "class"
            case .protocol: "protocol"
            case .typeAlias: "typealias"
            }
        }
    }

    private static func isCountedType(_ object: RuntimeObject, excludesUnexportedTypes: Bool) -> Bool {
        switch object.kind {
        case .c, .objc(.type), .swift(.type):
            break
        // The word cloud asks for no C++ objects (`objects(in:)`'s default).
        case .objc(.category), .swift(.extension), .swift(.conformance), .cPlusPlus:
            return false
        }
        if isLeftOut(object) {
            return false
        }
        if excludesUnexportedTypes, object.properties.contains(.isNotExported) {
            return false
        }
        return true
    }

    /// The Objective-C face of a Swift type, a specialized type or a local type.
    private static func isLeftOut(_ object: RuntimeObject) -> Bool {
        if object.properties.contains(.isSpecialized) || object.properties.contains(.isLocalType) {
            return true
        }
        switch object.kind {
        case .objc(.type(.class)):
            return object.properties.contains(.isSwiftClass)
        case .objc(.type(.protocol)):
            return object.properties.contains(.isSwiftProtocol)
        default:
            return false
        }
    }

    private static func typeCategory(of kind: RuntimeObjectKind) -> NamingWordCategory {
        switch kind {
        case .objc(.type(.class)), .objc(.category(.class)), .swift(.type(.class)), .swift(.extension(.class)), .swift(.conformance(.class)):
            .class
        case .objc(.type(.protocol)), .objc(.category(.protocol)), .swift(.type(.protocol)), .swift(.extension(.protocol)), .swift(.conformance(.protocol)):
            .protocol
        default:
            .valueType
        }
    }

    private static func memberCategory(of group: NamingMemberGroup) -> NamingWordCategory {
        switch group {
        case .properties: .property
        case .methods: .method
        case .instanceVariables, .enumCases: .otherMember
        }
    }

    // MARK: - Counting

    private struct CountedName {
        let usage: NamingWordUsage
        let category: NamingWordCategory
        /// As spelled; a word may appear more than once.
        let words: [String]
    }

    private struct MemberIdentity: Hashable {
        let group: NamingMemberGroup
        let name: String
    }

    private struct WordTally {
        var usages: [NamingWordUsage] = []
        var countsByCategory: [NamingWordCategory: Int] = [:]
        var countsBySpelling: [String: Int] = [:]
    }

    private static func aggregate(_ countedNames: [CountedName], categories: [NamingWordCategory], lowercasesWords: Bool) -> [NamingWordCount] {
        var talliesByKey: [String: WordTally] = [:]
        var namesByCategory: [NamingWordCategory: Int] = [:]
        var countedNameTotal = 0
        for countedName in countedNames where !countedName.words.isEmpty {
            countedNameTotal += 1
            namesByCategory[countedName.category, default: 0] += 1
            var keysOfThisName: Set<String> = []
            for spelling in countedName.words {
                let key = spelling.lowercased()
                guard !keysOfThisName.contains(key) else { continue }
                keysOfThisName.insert(key)
                talliesByKey[key, default: WordTally()].usages.append(countedName.usage)
                talliesByKey[key]?.countsByCategory[countedName.category, default: 0] += 1
                talliesByKey[key]?.countsBySpelling[spelling, default: 0] += 1
            }
        }
        let categoryShares = Dictionary(uniqueKeysWithValues: categories.map { category in
            (category, countedNameTotal == 0 ? 0 : Double(namesByCategory[category] ?? 0) / Double(countedNameTotal))
        })
        let wordCounts = talliesByKey.map { key, tally in
            let spelling = tally.countsBySpelling.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? key
            return NamingWordCount(
                key: key,
                word: NamingWordTokenizer.displayedWord(spelling, isLowercased: lowercasesWords),
                category: representativeCategory(countsByCategory: tally.countsByCategory, wordTotal: tally.usages.count, categoryShares: categoryShares, categories: categories),
                usages: sortedUsages(tally.usages)
            )
        }
        return wordCounts.sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.word.lowercased() < rhs.word.lowercased()
        }
    }

    /// The category whose names hold the word more often than that category's
    /// share of all names would suggest — by the widest margin — among the
    /// categories at least three names of which hold it; when none has
    /// three, the one most of its names belong to. Not the majority alone:
    /// methods outnumber every other member, and by majority nearly every
    /// common member word would be a method word.
    static func representativeCategory(
        countsByCategory: [NamingWordCategory: Int],
        wordTotal: Int,
        categoryShares: [NamingWordCategory: Double],
        categories: [NamingWordCategory]
    ) -> NamingWordCategory {
        let minimumNameCount = 3
        var bestCategory: NamingWordCategory?
        var bestMargin = -Double.infinity
        for category in categories {
            let count = countsByCategory[category] ?? 0
            guard count >= minimumNameCount, wordTotal > 0 else { continue }
            let margin = Double(count) / Double(wordTotal) - (categoryShares[category] ?? 0)
            if margin > bestMargin {
                bestMargin = margin
                bestCategory = category
            }
        }
        if let bestCategory {
            return bestCategory
        }
        var majorityCategory = categories[0]
        var majorityCount = -1
        for category in categories {
            let count = countsByCategory[category] ?? 0
            if count > majorityCount {
                majorityCount = count
                majorityCategory = category
            }
        }
        return majorityCategory
    }

    private static func sortedUsages(_ usages: [NamingWordUsage]) -> [NamingWordUsage] {
        usages.sorted { lhs, rhs in
            if lhs.isPrivate != rhs.isPrivate {
                return !lhs.isPrivate
            }
            let lhsName = lhs.name.lowercased()
            let rhsName = rhs.name.lowercased()
            if lhsName != rhsName {
                return lhsName < rhsName
            }
            return typeName(of: lhs.object).lowercased() < typeName(of: rhs.object).lowercased()
        }
    }
}
