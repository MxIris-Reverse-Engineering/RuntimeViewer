import Foundation
import Semantic
import Testing
@testable import RuntimeViewerCore

/// The corpus store against a scripted builder: the build queue, the
/// subscription model of cancellation, failure and skip semantics, the
/// transformer fingerprint, the resident budget, and search delivery.
@Suite("RuntimeInterfaceCorpusStore", .serialized)
struct RuntimeInterfaceCorpusStoreTests {
    /// A builder whose images, delays and failures are scripted per test.
    final class ScriptedBuilder: RuntimeInterfaceCorpusBuilding, @unchecked Sendable {
        var objectNamesByImagePath: [String: [String]] = [:]
        var failingImagePaths: Set<String> = []
        var failingObjectNames: Set<String> = []
        var delayPerObjectNanoseconds: UInt64 = 0
        private(set) var printedObjectNames: [String] = []
        private let lock = NSLock()

        func corpusObjects(in imagePath: String) async throws -> [RuntimeObject] {
            if failingImagePaths.contains(imagePath) {
                throw ScriptedError.imageFailed(imagePath)
            }
            return (objectNamesByImagePath[imagePath] ?? []).map { name in
                RuntimeObject(name: name, displayName: name, kind: .objc(.type(.class)), imagePath: imagePath, children: [])
            }
        }

        func corpusEntry(for object: RuntimeObject, transformer: Transformer.Configuration) async throws -> RuntimeInterfaceCorpusEntry? {
            if delayPerObjectNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayPerObjectNanoseconds)
            }
            if failingObjectNames.contains(object.name) {
                throw ScriptedError.objectFailed(object.name)
            }
            lock.withLock { printedObjectNames.append(object.name) }
            let interface = SemanticString {
                Keyword("class")
                Standard(" ")
                TypeName(kind: .class, object.name)
                Standard(" {\n    ")
                Keyword("var")
                Standard(" ")
                Variable("member" + object.name)
                Standard(": Int\n}")
            }.frozen()
            let members = RuntimeMemberDeclarationLocator.locate(
                [RuntimeMemberDeclaration(name: "member" + object.name, kind: .swiftVariable, isStatic: false, declarationText: "", lineNumber: nil)],
                in: interface
            )
            return RuntimeInterfaceCorpusEntry(object: object, interface: interface, members: members)
        }
    }

    enum ScriptedError: Swift.Error {
        case imageFailed(String)
        case objectFailed(String)
    }

    private static let imageA = "/images/A"
    private static let imageB = "/images/B"

    /// The store holds its builder `unowned` — the engine owns both — so a
    /// test keeps the builder alive for as long as it uses the store.
    struct Fixture {
        let store: RuntimeInterfaceCorpusStore
        let builder: ScriptedBuilder
    }

    private func makeStore(_ configure: (ScriptedBuilder) -> Void = { _ in }) -> Fixture {
        let builder = ScriptedBuilder()
        builder.objectNamesByImagePath = [Self.imageA: ["Alpha", "Beta"], Self.imageB: ["Gamma"]]
        configure(builder)
        return Fixture(store: RuntimeInterfaceCorpusStore(builder: builder), builder: builder)
    }

    @Test("a built image is searchable by text and by member name")
    func buildAndSearch() async throws {
        let fixture = makeStore()
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let summary = try await store.build(imagePath: Self.imageA, transformer: .default)
        #expect(summary.objectCount == 2)
        #expect(summary.skippedCount == 0)
        #expect(summary.byteCount > 0)

        var matches: [RuntimeInterfaceSearchMatch] = []
        let searchSummary = try await store.searchInterfaces(RuntimeInterfaceSearchQuery(text: "memberAlpha"), indexedImagePaths: [Self.imageA, Self.imageB]) { batch in
            matches += batch
        }
        #expect(searchSummary.totalMatchCount == 1)
        #expect(searchSummary.scannedImageCount == 1)
        #expect(searchSummary.scannedObjectCount == 2)
        #expect(searchSummary.unbuiltIndexedImagePaths == [Self.imageB])
        #expect(matches.first?.object.name == "Alpha")
        #expect(matches.first?.lineNumber == 2)

        var memberMatches: [RuntimeMemberMatch] = []
        let memberSummary = try await store.searchMembers(RuntimeMemberSearchQuery(text: "beta", kinds: [.swiftVariable]), indexedImagePaths: []) { batch in
            memberMatches += batch
        }
        #expect(memberSummary.totalMatchCount == 1)
        #expect(memberMatches.first?.member.name == "memberBeta")
        #expect(memberMatches.first?.member.lineNumber == 2)
        #expect(memberMatches.first?.matchRangeInName == RuntimeTextRange(location: 6, length: 4))

        let filtered = try await store.searchMembers(RuntimeMemberSearchQuery(text: "beta", kinds: [.objcMethod]), indexedImagePaths: []) { _ in }
        #expect(filtered.totalMatchCount == 0)
    }

    @Test("a second build of the same image returns the corpus already built")
    func rebuildIsFree() async throws {
        let fixture = makeStore()
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let builder = fixture.builder
        _ = try await store.build(imagePath: Self.imageA, transformer: .default)
        _ = try await store.build(imagePath: Self.imageA, transformer: .default)
        #expect(builder.printedObjectNames == ["Alpha", "Beta"])
    }

    @Test("an object that fails to print is skipped and counted; the build still succeeds")
    func skippedObject() async throws {
        let fixture = makeStore { $0.failingObjectNames = ["Beta"] }
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let summary = try await store.build(imagePath: Self.imageA, transformer: .default)
        #expect(summary.objectCount == 1)
        #expect(summary.skippedCount == 1)
        #expect(await store.coverage(indexedImagePaths: []).statesByImagePath[Self.imageA]?.isBuilt == true)
    }

    @Test("a failed build is remembered until the image is asked for again")
    func failedBuild() async throws {
        let fixture = makeStore { $0.failingImagePaths = [Self.imageA] }
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let builder = fixture.builder
        await #expect(throws: ScriptedError.self) {
            try await store.build(imagePath: Self.imageA, transformer: .default)
        }
        guard case .failed = await store.coverage(indexedImagePaths: []).statesByImagePath[Self.imageA] else {
            Issue.record("expected a failed state")
            return
        }
        builder.failingImagePaths = []
        let summary = try await store.build(imagePath: Self.imageA, transformer: .default)
        #expect(summary.objectCount == 2)
    }

    @Test("cancelling one of two subscribers leaves the build running")
    func subscriptionRefcount() async throws {
        let fixture = makeStore { $0.delayPerObjectNanoseconds = 50_000_000 }
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let first = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
        let second = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
        try await Task.sleep(nanoseconds: 20_000_000)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let summary = try await second.value
        #expect(summary.objectCount == 2)
    }

    @Test("cancelling the last subscriber cancels the build and leaves nothing behind")
    func lastSubscriberCancels() async throws {
        let fixture = makeStore { $0.delayPerObjectNanoseconds = 50_000_000 }
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let builder = fixture.builder
        let only = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
        try await Task.sleep(nanoseconds: 20_000_000)
        only.cancel()
        await #expect(throws: CancellationError.self) { try await only.value }
        // The build task observes the cancellation on its next await.
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(await store.coverage(indexedImagePaths: []).statesByImagePath[Self.imageA] == nil)
        #expect(builder.printedObjectNames.count < 2)
    }

    @Test("a different transformer evicts and rebuilds")
    func transformerFingerprint() async throws {
        let fixture = makeStore()
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let builder = fixture.builder
        _ = try await store.build(imagePath: Self.imageA, transformer: .default)
        var changed = Transformer.Configuration.default
        changed.objc.cType.isEnabled.toggle()
        _ = try await store.build(imagePath: Self.imageA, transformer: changed)
        #expect(builder.printedObjectNames == ["Alpha", "Beta", "Alpha", "Beta"])
        #expect(await store.corpus(for: Self.imageA)?.transformer == changed)
    }

    @Test("the resident budget evicts the least recently searched image, never the one just built")
    func residentBudget() async throws {
        let fixture = makeStore()
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        _ = try await store.build(imagePath: Self.imageA, transformer: .default)
        let byteCountA = await store.residentByteCount
        await store.setResidentByteLimit(byteCountA + 1)
        _ = try await store.build(imagePath: Self.imageB, transformer: .default)
        #expect(await store.builtImagePaths == [Self.imageB])
    }

    @Test("collection stops at the limit while the count goes on")
    func truncation() async throws {
        let fixture = makeStore()
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        _ = try await store.build(imagePath: Self.imageA, transformer: .default)
        _ = try await store.build(imagePath: Self.imageB, transformer: .default)
        var matches: [RuntimeInterfaceSearchMatch] = []
        let summary = try await store.searchInterfaces(RuntimeInterfaceSearchQuery(text: "member", resultLimit: 2), indexedImagePaths: []) { batch in
            matches += batch
        }
        #expect(summary.totalMatchCount == 3)
        #expect(summary.isTruncated)
        #expect(matches.count == 2)
    }

    @Test("evicting drops the corpus and its failure record")
    func eviction() async throws {
        let fixture = makeStore()
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        _ = try await store.build(imagePath: Self.imageA, transformer: .default)
        _ = try await store.build(imagePath: Self.imageB, transformer: .default)
        await store.evict(imagePath: Self.imageA)
        #expect(await store.builtImagePaths == [Self.imageB])
        await store.evictAll()
        #expect(await store.builtImagePaths.isEmpty)
        #expect(await store.residentByteCount == 0)
    }
}
