import Foundation
import Testing
@testable import RuntimeViewerCore

/// The Find navigator's engine requests against real system frameworks:
/// a corpus built for Foundation, text and member searches over it, and
/// relationship trees anchored on classes and protocols that have been
/// stable for decades.
@Suite("RuntimeInterfaceSearch", .serialized)
struct RuntimeInterfaceSearchTests {
    private enum Anchors {
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
        static let libobjcPath = "/usr/lib/libobjc.A.dylib"
    }

    private static func makeEngine(_ label: String) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: "test-search-" + label)
        try await engine.connect()
        try await engine.loadImage(at: Anchors.libobjcPath)
        try await engine.loadImage(at: Anchors.foundationPath)
        return engine
    }

    @Test("a corpus is built once and searched by text")
    func textSearch() async throws {
        let engine = try await Self.makeEngine("text")
        var progressReports: [RuntimeInterfaceCorpusBuildProgress] = []
        let summary = try await engine.buildInterfaceCorpus(for: Anchors.foundationPath, transformer: .default) { progress in
            progressReports.append(progress)
        }
        #expect(summary.objectCount > 1000)
        #expect(progressReports.last?.built == progressReports.last?.total)

        let coverage = try await engine.interfaceCorpusCoverage()
        #expect(coverage.statesByImagePath[Anchors.foundationPath]?.isBuilt == true)
        #expect(coverage.residentByteCount == summary.byteCount)

        var matches: [RuntimeInterfaceSearchMatch] = []
        let searchSummary = try await engine.searchInterfaces(RuntimeInterfaceSearchQuery(text: "NSMutableString", matchMode: .matchingWord, isCaseSensitive: true)) { batch in
            matches += batch
        }
        #expect(searchSummary.totalMatchCount > 0)
        #expect(searchSummary.scannedImageCount == 1)
        #expect(searchSummary.unbuiltIndexedImagePaths == [Anchors.libobjcPath])
        #expect(matches.contains { $0.object.name == "NSMutableString" && $0.object.kind == .objc(.type(.class)) })
        for match in matches.prefix(50) {
            #expect(match.lineNumber >= 1)
            let start = match.lineText.utf16.index(match.lineText.startIndex, offsetBy: match.matchRangeInLine.location)
            let end = match.lineText.utf16.index(start, offsetBy: match.matchRangeInLine.length)
            #expect(String(match.lineText[start ..< end]) == "NSMutableString")
        }

        // Asking again is free: the corpus is already there.
        let again = try await engine.buildInterfaceCorpus(for: Anchors.foundationPath, transformer: .default)
        #expect(again == summary)

        try await engine.evictInterfaceCorpus(for: nil)
        #expect(try await engine.interfaceCorpusCoverage().statesByImagePath.isEmpty)
    }

    @Test("members are listed from the structures and located in the text")
    func memberSearch() async throws {
        let engine = try await Self.makeEngine("members")
        _ = try await engine.buildInterfaceCorpus(for: Anchors.foundationPath, transformer: .default)

        var methodMatches: [RuntimeMemberMatch] = []
        let methodSummary = try await engine.searchMembers(RuntimeMemberSearchQuery(text: "initWithFormat:", kinds: [.objcMethod], isCaseSensitive: true)) { batch in
            methodMatches += batch
        }
        #expect(methodSummary.totalMatchCount > 0)
        #expect(methodMatches.allSatisfy { $0.member.kind == .objcMethod })
        // `-[NSString initWithFormat:]` is declared by a category in the
        // headers, but the class's runtime method list carries it, so it is
        // a member of the class object.
        let located = try #require(methodMatches.first { $0.object.name == "NSString" && $0.object.kind == .objc(.type(.class)) && $0.member.name == "initWithFormat:" })
        #expect(located.member.lineNumber != nil)
        #expect(located.member.declarationText.contains("initWithFormat:"))
        let locatedCount = methodMatches.filter { $0.member.lineNumber != nil }.count
        #expect(locatedCount * 10 >= methodMatches.count * 9, "\(locatedCount) of \(methodMatches.count) methods located")

        var propertyMatches: [RuntimeMemberMatch] = []
        _ = try await engine.searchMembers(RuntimeMemberSearchQuery(text: "length", kinds: [.objcProperty])) { batch in
            propertyMatches += batch
        }
        #expect(propertyMatches.contains { $0.object.name == "NSString" && $0.member.name == "length" && $0.member.lineNumber != nil })

        var swiftMatches: [RuntimeMemberMatch] = []
        let swiftSummary = try await engine.searchMembers(RuntimeMemberSearchQuery(text: "", kinds: [.swiftFunction, .swiftVariable, .swiftField])) { batch in
            swiftMatches += batch
        }
        // An empty query matches nothing; member search is a substring search.
        #expect(swiftSummary.totalMatchCount == 0)
        _ = swiftMatches

        var descriptionMatches: [RuntimeMemberMatch] = []
        _ = try await engine.searchMembers(RuntimeMemberSearchQuery(text: "description", kinds: [.swiftVariable, .swiftFunction])) { batch in
            descriptionMatches += batch
        }
        #expect(descriptionMatches.contains { $0.object.kind.isSwift })
    }

    @Test("ancestors of an Objective-C class nest its superclass chain and protocols")
    func objcAncestors() async throws {
        let engine = try await Self.makeEngine("objc-ancestors")
        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSMutableString", relationship: .ancestors, isCaseSensitive: true))
        let tree = try #require(trees.first { $0.root.name == "NSMutableString" && $0.root.kind == .objc(.type(.class)) })
        let superclass = try #require(tree.nodes.first { $0.name == "NSString" })
        #expect(superclass.isResolved)
        let root = try #require(superclass.children.first { $0.name == "NSObject" })
        #expect(root.isResolved)
        #expect(root.children.contains { $0.name == "NSObject" && $0.object?.kind == .objc(.type(.protocol)) })
        // NSString adopts NSCopying inline.
        #expect(superclass.children.contains { $0.name == "NSCopying" })
    }

    @Test("descendants of an Objective-C class are nested transitively")
    func objcDescendants() async throws {
        let engine = try await Self.makeEngine("objc-descendants")
        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSString", relationship: .descendants, isCaseSensitive: true))
        let tree = try #require(trees.first { $0.root.name == "NSString" && $0.root.kind == .objc(.type(.class)) })
        let mutable = try #require(tree.nodes.first { $0.name == "NSMutableString" })
        #expect(mutable.isResolved)
        #expect(!mutable.children.isEmpty)
    }

    @Test("a relationship search limited to some images lists their types and the paths to them")
    func relationshipsLimitedToImages() async throws {
        let engine = try await Self.makeEngine("relationships-limited-to-images")
        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSObject", relationship: .descendants, isCaseSensitive: true, imagePaths: [Anchors.foundationPath]))

        // The type asked about is found outside the images: NSObject is libobjc's.
        let tree = try #require(trees.first { $0.root.name == "NSObject" && $0.root.kind == .objc(.type(.class)) })
        #expect(tree.root.imagePath == Anchors.libobjcPath)
        func everyNode(of nodes: [RuntimeRelationshipNode]) -> [RuntimeRelationshipNode] {
            nodes.flatMap { [$0] + everyNode(of: $0.children) }
        }
        func leadsIntoFoundation(_ node: RuntimeRelationshipNode) -> Bool {
            node.object?.imagePath == Anchors.foundationPath || node.children.contains(where: leadsIntoFoundation)
        }
        let nodes = everyNode(of: tree.nodes)
        #expect(nodes.contains { $0.name == "NSString" })
        #expect(nodes.allSatisfy(leadsIntoFoundation), "\(nodes.filter { !leadsIntoFoundation($0) }.prefix(5).map(\.name)) lead nowhere into Foundation")
    }

    @Test("the types a relationship search starts from match on their own name, under the query's match style")
    func relationshipCandidatesFollowTheMatchStyle() async throws {
        let engine = try await Self.makeEngine("relationship-match-styles")
        func rootNames(_ text: String, _ matchMode: RuntimeInterfaceSearchMatchMode) async throws -> [String] {
            let query = RuntimeTypeRelationshipsQuery(text: text, matchMode: matchMode, relationship: .ancestors, candidateLimit: .max)
            return try await engine.typeRelationships(query).map(\.root.displayName)
        }
        func ownName(_ displayName: String) -> String {
            displayName.components(separatedBy: ".").last ?? displayName
        }

        // Matching Word is the whole name: NSString, never NSMutableString.
        let matchingWord = try await rootNames("nsstring", .matchingWord)
        #expect(matchingWord.contains("NSString"))
        #expect(matchingWord.allSatisfy { ownName($0).caseInsensitiveCompare("NSString") == .orderedSame }, "\(matchingWord)")

        // Starting With and Ending With anchor at the ends of the name.
        let startingWith = try await rootNames("NSMutableStr", .startingWith)
        #expect(startingWith.contains("NSMutableString"))
        #expect(startingWith.allSatisfy { ownName($0).lowercased().hasPrefix("nsmutablestr") }, "\(startingWith)")
        let endingWith = try await rootNames("SecureCoding", .endingWith)
        #expect(endingWith.contains("NSSecureCoding"))
        #expect(endingWith.allSatisfy { ownName($0).lowercased().hasSuffix("securecoding") }, "\(endingWith)")

        // A module is no type's name; a query that names one reaches a type
        // through its qualified name.
        #expect(try await rootNames("Foundation", .matchingWord).isEmpty)
        #expect(try await rootNames("Foundation.LocalizedError", .matchingWord) == ["Foundation.LocalizedError"])
    }

    @Test("conformers of an Objective-C protocol, and the protocols refining it")
    func objcProtocolRelationships() async throws {
        let engine = try await Self.makeEngine("objc-protocol")
        let conformers = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSCoding", relationship: .conformers, isCaseSensitive: true))
        let conformerTree = try #require(conformers.first { $0.root.name == "NSCoding" })
        // Direct adopters only — `NSString` adopts `NSSecureCoding`, which
        // refines `NSCoding`, so it is not here; that is the Inspector's rule.
        #expect(!conformerTree.nodes.isEmpty)
        #expect(conformerTree.nodes.allSatisfy { $0.object?.kind == .objc(.type(.class)) || $0.object?.kind == .swift(.type(.class)) })
        #expect(!conformerTree.nodes.contains { $0.name == "NSString" })

        let descendants = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSCoding", relationship: .descendants, isCaseSensitive: true))
        let descendantTree = try #require(descendants.first { $0.root.name == "NSCoding" })
        #expect(descendantTree.nodes.contains { $0.name == "NSSecureCoding" && $0.isResolved })

        let ancestors = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSSecureCoding", relationship: .ancestors, isCaseSensitive: true))
        let ancestorTree = try #require(ancestors.first { $0.root.name == "NSSecureCoding" })
        #expect(ancestorTree.nodes.contains { $0.name == "NSCoding" && $0.isResolved })
    }

    @Test("Swift protocol refinements are read from requirement signatures")
    func swiftProtocolRefinements() async throws {
        let engine = try await Self.makeEngine("swift-protocol")
        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "LocalizedError", relationship: .ancestors))
        let tree = try #require(trees.first { $0.root.displayName.hasSuffix("LocalizedError") && $0.root.kind == .swift(.type(.protocol)) })
        // `Foundation.LocalizedError: Swift.Error`; the standard library is not
        // indexed here, so the node is named but unresolved.
        #expect(tree.nodes.contains { $0.name.hasSuffix("Error") })

        let candidates = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "error", relationship: .ancestors, candidateLimit: 5))
        #expect(candidates.count <= 5)
    }

    @Test("a Swift class reaches its Objective-C superclass")
    func swiftClassAncestors() async throws {
        let engine = try await Self.makeEngine("swift-class")
        let objects = try await engine.objects(in: Anchors.foundationPath)
        // Any Swift class in the overlay with a superclass will do; the walk
        // must end at an Objective-C root when the chain crosses languages.
        for candidate in objects where candidate.kind == .swift(.type(.class)) {
            let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: candidate.displayName, relationship: .ancestors, isCaseSensitive: true))
            guard let tree = trees.first(where: { $0.root == candidate }),
                  let superclass = tree.nodes.first(where: { $0.object?.kind == .swift(.type(.class)) || $0.object?.kind == .objc(.type(.class)) || ($0.object == nil && !$0.name.isEmpty) })
            else { continue }
            #expect(!superclass.name.isEmpty)
            return
        }
        Issue.record("no Swift class with a superclass in the Foundation overlay")
    }

    /// Adopting an Objective-C protocol leaves a Swift class no Swift
    /// conformance record; the adoption is written into its Objective-C
    /// face, which Conforming Types reads. Ancestor Types has to agree.
    /// Foundation's `NSNotificationCenter.NotificationMessageKey` and a
    /// private `BridgeKey` adopt `NSCopying` on macOS 26.7 and 27.0.
    @Test("a Swift class lists the Objective-C protocols its Objective-C face adopts")
    func swiftClassAncestorsIncludeAdoptedObjCProtocols() async throws {
        let engine = try await Self.makeEngine("swift-class-objc-protocols")
        let conformerTrees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSCopying", matchMode: .matchingWord, relationship: .conformers, isCaseSensitive: true))
        let swiftClasses = conformerTrees
            .filter { $0.root.kind == .objc(.type(.protocol)) }
            .flatMap(\.nodes)
            .compactMap(\.object)
            .filter { $0.kind == .swift(.type(.class)) }
        try #require(!swiftClasses.isEmpty, "Foundation has no Swift class adopting NSCopying")

        var classesMissingTheProtocol: [String] = []
        for swiftClass in swiftClasses {
            let ownName = swiftClass.displayName.components(separatedBy: ".").last ?? swiftClass.displayName
            let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: ownName, matchMode: .matchingWord, relationship: .ancestors, isCaseSensitive: true, candidateLimit: .max))
            let tree = try #require(trees.first { $0.root == swiftClass }, "no Ancestor tree for \(swiftClass.displayName)")
            // Before: only the protocols of its Swift conformance records.
            if !tree.nodes.contains(where: { $0.name == "NSCopying" && $0.object?.kind == .objc(.type(.protocol)) }) {
                classesMissingTheProtocol.append("\(swiftClass.displayName): \(tree.nodes.map(\.name))")
            }
        }
        #expect(classesMissingTheProtocol.isEmpty, "\(classesMissingTheProtocol)")
    }

    /// What a search request pushes across a connection, encoded as it
    /// travels.
    final class EncodedProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [Data] = []

        var all: [Data] {
            lock.withLock { payloads }
        }

        func append(_ payload: Data?) {
            guard let payload else { return }
            lock.withLock { payloads.append(payload) }
        }
    }

    /// The objects encoded in `payload`: every dictionary with an object's
    /// keys, nested ones included.
    private static func encodedObjectCount(in payload: Data) throws -> Int {
        func count(in value: Any) -> Int {
            if let dictionary = value as? [String: Any] {
                let ownCount = dictionary["imagePath"] != nil && dictionary["displayName"] != nil ? 1 : 0
                return ownCount + dictionary.values.reduce(0) { total, nestedValue in total + count(in: nestedValue) }
            }
            if let array = value as? [Any] {
                return array.reduce(0) { total, element in total + count(in: element) }
            }
            return 0
        }
        return count(in: try JSONSerialization.jsonObject(with: payload))
    }

    /// A search's progress crosses a connection as JSON, one batch per
    /// image. Every match used to carry its object, nested types and all, so
    /// an object went across once for each of its hits.
    @Test("a search's progress carries each object once, however many of its hits a batch holds")
    func searchProgressCarriesEachObjectOnce() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "test-search-progress-objects")
        try await engine.connect()
        try await engine.loadImage(at: Anchors.libobjcPath)
        _ = try await engine.buildInterfaceCorpus(for: Anchors.libobjcPath, transformer: .default)

        let textQuery = RuntimeInterfaceSearchQuery(text: "id", matchMode: .matchingWord, isCaseSensitive: true)
        let textProgress = EncodedProgress()
        _ = try await RuntimeEngine.SearchInterfacesRequest(query: textQuery).perform(on: engine) { batch in
            textProgress.append(try? JSONEncoder().encode(batch))
        }
        var textMatches: [RuntimeInterfaceSearchMatch] = []
        _ = try await engine.searchInterfaces(textQuery) { batch in
            textMatches += batch
        }

        let memberQuery = RuntimeMemberSearchQuery(text: "init", matchMode: .startingWith, isCaseSensitive: true)
        let memberProgress = EncodedProgress()
        _ = try await RuntimeEngine.SearchMembersRequest(query: memberQuery).perform(on: engine) { batch in
            memberProgress.append(try? JSONEncoder().encode(batch))
        }
        var memberMatches: [RuntimeMemberMatch] = []
        _ = try await engine.searchMembers(memberQuery) { batch in
            memberMatches += batch
        }

        let textObjectCount = Set(textMatches.map(\.object.key)).count
        let memberObjectCount = Set(memberMatches.map(\.object.key)).count
        // The case worth sending once: objects with more than one hit.
        #expect(textMatches.count > 2 * textObjectCount, "\(textMatches.count) text matches in \(textObjectCount) objects")
        #expect(memberMatches.count > memberObjectCount, "\(memberMatches.count) member matches in \(memberObjectCount) objects")
        let textEncodedObjectCount = try textProgress.all.reduce(0) { total, payload in total + (try Self.encodedObjectCount(in: payload)) }
        let memberEncodedObjectCount = try memberProgress.all.reduce(0) { total, payload in total + (try Self.encodedObjectCount(in: payload)) }
        #expect(textEncodedObjectCount == textObjectCount)
        #expect(memberEncodedObjectCount == memberObjectCount)
    }

    /// A walk cut short hands back only what it had reached, so a cancelled
    /// search throws instead. The engine here runs in process — the test
    /// process names no local runtime service — so cancelling the task asking
    /// reaches the walk directly. This proves the checks on the way in; a
    /// cancellation in the middle of a walk has no stable point to inject.
    @Test("a cancelled relationship search throws instead of returning a partial tree")
    func cancelledRelationshipSearchThrows() async throws {
        let engine = try await Self.makeEngine("relationships-cancelled")
        let search = Task {
            try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSObject", relationship: .descendants, isCaseSensitive: true))
        }
        search.cancel()

        // Before: nothing on the way checked, and the whole tree came back.
        await #expect(throws: CancellationError.self) {
            try await search.value
        }
    }

    /// A relationship search has no partial result to keep, so a regular
    /// expression that spends its budget fails it, in words. The resolver is
    /// the engine's, over the same sections, with no budget at all: the
    /// first type name the expression reads spends it.
    @Test("a relationship search whose regular expression spends its budget fails in words")
    func relationshipSearchOverBudgetFailsReadably() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "test-search-relationships-budget")
        try await engine.connect()
        try await engine.loadImage(at: Anchors.libobjcPath)
        let resolver = RuntimeTypeRelationshipsResolver(
            objcSectionFactory: await engine.objcSectionFactory,
            swiftSectionFactory: await engine.swiftSectionFactory,
            relationshipsResolver: await engine.relationshipsResolver,
            regularExpressionTimeLimit: 0
        )
        let query = RuntimeTypeRelationshipsQuery(text: "^NSObj", matchMode: .regularExpression, relationship: .ancestors)

        let error = await #expect(throws: RuntimeInterfaceTextMatcher.PatternError.regularExpressionTooExpensive(pattern: "^NSObj")) {
            try await resolver.trees(for: query)
        }
        #expect(error?.localizedDescription == "“^NSObj” takes too long to match. Nested repetition such as (\\w+)+ is the usual cause.")
    }
}
