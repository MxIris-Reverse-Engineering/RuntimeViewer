import Foundation
import Testing
@testable import RuntimeViewerCore

/// `RuntimeEngine.members(in:shownUnder:)`, which the naming word cloud counts
/// member names from: an image's corpus listed object by object, members
/// shown by the rule a member search applies.
@Suite("Corpus members", .serialized)
struct RuntimeCorpusMembersTests {
    private enum Anchors {
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
        static let libobjcPath = "/usr/lib/libobjc.A.dylib"
    }

    private struct MemberKey: Hashable {
        let object: RuntimeObjectKey
        let name: String
        let kind: RuntimeMemberKind
    }

    private static func makeEngine(_ label: String) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: "test-corpus-members-" + label)
        try await engine.connect()
        try await engine.loadImage(at: Anchors.libobjcPath)
        try await engine.loadImage(at: Anchors.foundationPath)
        return engine
    }

    private static func strippingSynthesizedMethods() -> RuntimeObjectInterface.GenerationOptions {
        var options = RuntimeObjectInterface.GenerationOptions()
        options.objcHeaderOptions.stripSynthesizedMethods = true
        return options
    }

    @Test("an image without a corpus has no members to list")
    func imageWithoutCorpus() async throws {
        let engine = try await Self.makeEngine("unbuilt")
        defer { Task { await engine.stop() } }

        #expect(try await engine.members(in: Anchors.libobjcPath) == nil)
    }

    @Test("without options, the members are the ones a member search finds")
    func membersMatchAMemberSearch() async throws {
        let engine = try await Self.makeEngine("search")
        defer { Task { await engine.stop() } }
        _ = try await engine.buildInterfaceCorpus(for: Anchors.foundationPath, transformer: .default)

        let listed = try #require(try await engine.members(in: Anchors.foundationPath))
        #expect(listed.allSatisfy { $0.object.children.isEmpty }, "objects come without their children")
        let listedKeys = Set(listed.flatMap { objectMembers in
            objectMembers.members
                .filter { $0.name.contains("length") && ($0.kind == .objcProperty || $0.kind == .objcMethod) }
                .map { MemberKey(object: objectMembers.object.key, name: $0.name, kind: $0.kind) }
        })

        var foundKeys: Set<MemberKey> = []
        _ = try await engine.searchMembers(RuntimeMemberSearchQuery(
            text: "length",
            kinds: [.objcProperty, .objcMethod],
            isCaseSensitive: true,
            resultLimit: .max,
            imagePaths: [Anchors.foundationPath]
        )) { batch in
            for match in batch {
                foundKeys.insert(MemberKey(object: match.object.key, name: match.member.name, kind: match.member.kind))
            }
        }

        #expect(!foundKeys.isEmpty)
        // A search reports a protocol copied into another image once, and
        // counts the rest; the listing has every copy. So every hit is
        // listed, and the listing may hold more.
        #expect(foundKeys.isSubset(of: listedKeys), "\(foundKeys.subtracting(listedKeys).prefix(5))")
    }

    @Test("under options that strip synthesized methods, the accessors are not listed and the properties are")
    func optionsHideWhatTheyHide() async throws {
        let engine = try await Self.makeEngine("options")
        defer { Task { await engine.stop() } }
        _ = try await engine.buildInterfaceCorpus(for: Anchors.foundationPath, transformer: .default)

        let everything = try #require(try await engine.members(in: Anchors.foundationPath))
        let stripped = try #require(try await engine.members(in: Anchors.foundationPath, shownUnder: Self.strippingSynthesizedMethods()))

        func count(_ kind: RuntimeMemberKind, in listing: [RuntimeObjectMembers]) -> Int {
            listing.reduce(0) { total, objectMembers in total + objectMembers.members.count { $0.kind == kind } }
        }
        #expect(count(.objcMethod, in: stripped) < count(.objcMethod, in: everything))
        #expect(count(.objcProperty, in: stripped) == count(.objcProperty, in: everything))

        func nsStringMembers(in listing: [RuntimeObjectMembers]) throws -> [RuntimeObjectMembers.Member] {
            try #require(listing.first { $0.object.name == "NSString" && $0.object.kind == .objc(.type(.class)) }).members
        }
        let everyNSStringMember = try nsStringMembers(in: everything)
        let strippedNSStringMembers = try nsStringMembers(in: stripped)
        #expect(everyNSStringMember.contains { $0.name == "length" && $0.kind == .objcMethod })
        #expect(!strippedNSStringMembers.contains { $0.name == "length" && $0.kind == .objcMethod })
        #expect(strippedNSStringMembers.contains { $0.name == "length" && $0.kind == .objcProperty })
    }
}
