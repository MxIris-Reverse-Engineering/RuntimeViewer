import Foundation
import Testing
import RuntimeViewerCore

/// Every image compiled against an Objective-C protocol carries a full copy
/// of it. A relationship search shows one node per protocol, whichever images
/// carry it and whatever order they were indexed in.
@Suite("Relationship trees over Objective-C protocol copies", .serialized)
struct RuntimeTypeRelationshipsProtocolCopyTests {
    private enum Anchors {
        static let libobjcPath = "/usr/lib/libobjc.A.dylib"
        static let coreFoundationPath = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
    }

    private static func makeEngine(_ label: String, loading imagePaths: [String]) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: "test-protocol-copies-" + label)
        try await engine.connect()
        for imagePath in imagePaths {
            try await engine.loadImage(at: imagePath)
        }
        return engine
    }

    /// Fails loudly when the system stops carrying the copies a test relies
    /// on, instead of letting the test pass over nothing. CoreFoundation and
    /// Foundation both carry these on macOS 26.7 and 27.0.
    private static func requireCarried(_ protocolName: String, by imagePaths: [String], in engine: RuntimeEngine) async throws {
        for imagePath in imagePaths {
            let objects = try await engine.objects(in: imagePath)
            try #require(objects.contains { $0.name == protocolName && $0.kind == .objc(.type(.protocol)) }, "\(imagePath) no longer carries \(protocolName)")
        }
    }

    private static func everyLevel(of nodes: [RuntimeRelationshipNode]) -> [[RuntimeRelationshipNode]] {
        [nodes] + nodes.flatMap { everyLevel(of: $0.children) }
    }

    @Test("an Objective-C protocol several images carry is one candidate")
    func protocolCopiesAreOneCandidate() async throws {
        let engine = try await Self.makeEngine("candidates", loading: [Anchors.libobjcPath, Anchors.coreFoundationPath, Anchors.foundationPath])
        try await Self.requireCarried("NSObject", by: [Anchors.coreFoundationPath, Anchors.foundationPath], in: engine)

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSObject", matchMode: .matchingWord, relationship: .descendants, isCaseSensitive: true, candidateLimit: 2))
        let roots = trees.map { "\($0.root.kind) in \($0.root.imagePath)" }

        // Before: both slots went to CoreFoundation's and Foundation's copies
        // of the protocol, which sort ahead of /usr/lib.
        #expect(trees.contains { $0.root.kind == .objc(.type(.class)) && $0.root.imagePath == Anchors.libobjcPath }, "\(roots)")
        #expect(trees.count { $0.root.kind == .objc(.type(.protocol)) } == 1, "\(roots)")
    }

    @Test("a protocol refining another is one node however many images carry it")
    func refiningProtocolCopiesAreOneNode() async throws {
        let engine = try await Self.makeEngine("refining", loading: [Anchors.libobjcPath, Anchors.coreFoundationPath, Anchors.foundationPath])
        try await Self.requireCarried("NSSecureCoding", by: [Anchors.coreFoundationPath, Anchors.foundationPath], in: engine)

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSCoding", matchMode: .matchingWord, relationship: .descendants, isCaseSensitive: true))
        let tree = try #require(trees.first { $0.root.name == "NSCoding" })

        // Before: one NSSecureCoding per carrying image.
        #expect(tree.nodes.count { $0.name == "NSSecureCoding" } == 1, "\(tree.nodes.map(\.name))")
        let levelsWithRepeats = Self.everyLevel(of: tree.nodes)
            .map { level in level.map { "\(String(describing: $0.object?.kind))|\($0.name)" } }
            .filter { identities in Set(identities).count != identities.count }
        #expect(levelsWithRepeats.isEmpty, "\(levelsWithRepeats.count) levels repeat a node, the first: \(levelsWithRepeats.first ?? [])")
    }

    @Test("which copy a node stands for does not depend on the order images were indexed in")
    func copiesDoNotFollowIndexingOrder() async throws {
        let coreFoundationFirst = try await Self.makeEngine("core-foundation-first", loading: [Anchors.libobjcPath, Anchors.coreFoundationPath, Anchors.foundationPath])
        let foundationFirst = try await Self.makeEngine("foundation-first", loading: [Anchors.libobjcPath, Anchors.foundationPath, Anchors.coreFoundationPath])
        try await Self.requireCarried("NSSecureCoding", by: [Anchors.coreFoundationPath, Anchors.foundationPath], in: coreFoundationFirst)
        let query = RuntimeTypeRelationshipsQuery(text: "NSString", matchMode: .matchingWord, relationship: .ancestors, isCaseSensitive: true)

        let coreFoundationFirstTrees = try await coreFoundationFirst.typeRelationships(query)
        let foundationFirstTrees = try await foundationFirst.typeRelationships(query)
        let coreFoundationFirstTree = try #require(coreFoundationFirstTrees.first { $0.root.name == "NSString" })
        let foundationFirstTree = try #require(foundationFirstTrees.first { $0.root.name == "NSString" })

        // Before: NSSecureCoding and the rest went to whichever carrier was
        // indexed first — CoreFoundation in one engine, Foundation in the
        // other.
        #expect(coreFoundationFirstTree == foundationFirstTree)
        // NSString is Foundation's, and Foundation carries the protocols it
        // adopts: its own copies are the ones its metadata names.
        let secureCoding = try #require(coreFoundationFirstTree.nodes.first { $0.name == "NSSecureCoding" })
        #expect(secureCoding.object?.imagePath == coreFoundationFirstTree.root.imagePath)
    }

    @Test("a search limited to some images keeps a protocol any of them carries")
    func limitedSearchKeepsProtocolsItsImagesCarry() async throws {
        let engine = try await Self.makeEngine("limited", loading: [Anchors.libobjcPath, Anchors.coreFoundationPath, Anchors.foundationPath])
        try await Self.requireCarried("NSSecureCoding", by: [Anchors.coreFoundationPath, Anchors.foundationPath], in: engine)
        let foundationImagePath = try #require(try await engine.objects(in: Anchors.foundationPath).first?.imagePath)

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSArray", matchMode: .matchingWord, relationship: .ancestors, isCaseSensitive: true, imagePaths: [Anchors.foundationPath]))

        // NSArray is CoreFoundation's; the protocols it adopts are carried by
        // both images. Before: every one went to CoreFoundation, indexed
        // first, and the whole tree was cut away.
        let tree = try #require(trees.first { $0.root.name == "NSArray" })
        let secureCoding = try #require(tree.nodes.first { $0.name == "NSSecureCoding" })
        #expect(secureCoding.object?.imagePath == foundationImagePath)
    }

    @Test("the protocols refining a protocol are listed by name")
    func refiningProtocolsAreListedByName() async throws {
        let engine = try await Self.makeEngine("order", loading: [Anchors.libobjcPath, Anchors.foundationPath])
        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSObject", matchMode: .matchingWord, relationship: .descendants, isCaseSensitive: true))
        let tree = try #require(trees.first { $0.root.kind == .objc(.type(.protocol)) })
        try #require(tree.nodes.count >= 5)

        // Before: each level followed the dictionary order of the library's
        // protocol table, which changes with every launch.
        let unsortedLevels = Self.everyLevel(of: tree.nodes)
            .map { level in level.map(\.name) }
            .filter { names in names != names.sorted { left, right in left.localizedCaseInsensitiveCompare(right) == .orderedAscending } }
        #expect(unsortedLevels.isEmpty, "\(unsortedLevels.count) levels out of order, the first: \(unsortedLevels.first?.prefix(10).joined(separator: ", ") ?? "")")
    }

    @Test("a Swift class registered with the Objective-C runtime is one candidate, under its Swift face")
    func swiftClassObjCFaceIsNotACandidate() async throws {
        let engine = try await Self.makeEngine("objc-face", loading: [Anchors.libobjcPath, Anchors.foundationPath])
        let objcFaces = try await engine.objects(in: Anchors.foundationPath)
            .filter { $0.kind == .objc(.type(.class)) && $0.properties.contains(.isSwiftClass) }
            .sorted { left, right in left.name < right.name }
        var anchor: (objcFace: RuntimeObject, swiftFace: RuntimeObject)?
        for objcFace in objcFaces {
            if let swiftFace = try await engine.counterpart(for: objcFace) {
                anchor = (objcFace, swiftFace)
                break
            }
        }
        let (objcFace, swiftFace) = try #require(anchor, "Foundation registers no Swift class with the Objective-C runtime")

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: objcFace.name, matchMode: .matchingWord, relationship: .ancestors, isCaseSensitive: true))

        // Before: the Objective-C face was a candidate of its own, with a
        // tree that differs from its Swift face's.
        #expect(trees.map(\.root) == [swiftFace], "\(trees.map { "\($0.root.kind) \($0.root.displayName)" })")
    }

    /// The Swift face found from a private class's Objective-C class is
    /// materialized again from its mangled name, apart from the sidebar's
    /// object. Until the sidebar stopped spelling private discriminators
    /// (draft-private-discriminator-tag) the two were spelled differently, and
    /// a query matching both faces had to keep the sidebar's; now both are
    /// printed from the same demangled name, so the candidate carries the
    /// sidebar row's name and private declarations whichever it keeps.
    @Test("a Swift class both of whose faces match keeps the name the sidebar lists it under")
    func swiftFaceKeepsItsSidebarName() async throws {
        let engine = try await Self.makeEngine("sidebar-name", loading: [Anchors.libobjcPath, Anchors.foundationPath])
        let objects = try await engine.objects(in: Anchors.foundationPath)
        let sidebarSwiftClasses = objects.filter { $0.kind == .swift(.type(.class)) }
        var anchor: (sidebarSwiftFace: RuntimeObject, swiftFace: RuntimeObject, identifier: String)?
        let objcFaces = objects
            .filter { $0.kind == .objc(.type(.class)) && $0.properties.contains(.isSwiftClass) }
            .sorted { left, right in left.name < right.name }
        for objcFace in objcFaces {
            guard let swiftFace = try await engine.counterpart(for: objcFace),
                  let sidebarSwiftFace = sidebarSwiftClasses.first(where: { $0 == swiftFace }),
                  !sidebarSwiftFace.privateDeclarations.isEmpty,
                  let identifier = swiftFace.displayName.components(separatedBy: ".").last,
                  objcFace.name.contains(identifier),
                  sidebarSwiftFace.displayName.contains(identifier)
            else { continue }
            anchor = (sidebarSwiftFace, swiftFace, identifier)
            break
        }
        let (sidebarSwiftFace, swiftFace, identifier) = try #require(anchor, "Foundation has no private Swift class registered with the Objective-C runtime")

        #expect(swiftFace.displayName == sidebarSwiftFace.displayName)
        #expect(swiftFace.privateDeclarations == sidebarSwiftFace.privateDeclarations)

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: identifier, matchMode: .containing, relationship: .ancestors, isCaseSensitive: true, candidateLimit: .max))
        let tree = try #require(trees.first { $0.root == sidebarSwiftFace })

        #expect(tree.root.displayName == sidebarSwiftFace.displayName)
        #expect(tree.root.privateDeclarations == sidebarSwiftFace.privateDeclarations)
    }
}
