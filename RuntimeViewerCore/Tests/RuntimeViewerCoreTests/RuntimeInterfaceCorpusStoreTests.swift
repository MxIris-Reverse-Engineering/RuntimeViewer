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
        /// Overrides `delayPerObjectNanoseconds` for the objects it names.
        var delayNanosecondsByObjectName: [String: UInt64] = [:]
        private(set) var printedObjectNames: [String] = []
        private(set) var maximumConcurrentPrintCount = 0
        private var concurrentPrintCount = 0
        private let lock = NSLock()

        func corpusObjects(in imagePath: String) async throws -> [RuntimeObject] {
            if failingImagePaths.contains(imagePath) {
                throw ScriptedError.imageFailed(imagePath)
            }
            return (objectNamesByImagePath[imagePath] ?? []).map { name in
                RuntimeObject(name: name, displayName: name, kind: .objc(.type(.class)), imagePath: imagePath, children: [])
            }
        }

        func corpusPrint(for object: RuntimeObject, transformer: Transformer.Configuration) async throws -> RuntimeInterfaceCorpusPrint? {
            lock.withLock {
                concurrentPrintCount += 1
                maximumConcurrentPrintCount = max(maximumConcurrentPrintCount, concurrentPrintCount)
            }
            defer { lock.withLock { concurrentPrintCount -= 1 } }
            let delayNanoseconds = delayNanosecondsByObjectName[object.name] ?? delayPerObjectNanoseconds
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
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
            return RuntimeInterfaceCorpusPrint(
                object: object,
                interface: interface,
                visibilityRegions: .empty,
                members: [RuntimeMemberDeclaration(name: "member" + object.name, kind: .swiftVariable, isStatic: false, declarationText: "", lineNumber: nil)],
                ownDefinitionUTF8Length: interface.text.utf8.count
            )
        }
    }

    enum ScriptedError: Swift.Error {
        case imageFailed(String)
        case objectFailed(String)
    }

    private static let imageA = "/images/A"
    private static let imageB = "/images/B"
    private static let imageC = "/images/C"

    /// The store holds its builder weakly — the engine owns both — so a
    /// test keeps the builder alive for as long as it uses the store.
    struct Fixture {
        let store: RuntimeInterfaceCorpusStore
        let builder: ScriptedBuilder
    }

    private func makeStore(printingWidth: Int = 1, _ configure: (ScriptedBuilder) -> Void = { _ in }) -> Fixture {
        let builder = ScriptedBuilder()
        builder.objectNamesByImagePath = [Self.imageA: ["Alpha", "Beta"], Self.imageB: ["Gamma"]]
        configure(builder)
        return Fixture(store: RuntimeInterfaceCorpusStore(builder: builder, printingWidth: printingWidth), builder: builder)
    }

    private static let manyObjectNames = (1 ... 12).map { "Object\($0)" }

    @Test("objects printed side by side land in the listing order, whatever order they finish in")
    func parallelPrintsKeepListingOrder() async throws {
        let fixture = makeStore(printingWidth: 4) { builder in
            builder.objectNamesByImagePath[Self.imageC] = Self.manyObjectNames
            // Each object takes less time than the one before it, so they
            // finish in roughly the reverse of the order they started.
            for (index, name) in Self.manyObjectNames.enumerated() {
                builder.delayNanosecondsByObjectName[name] = UInt64(Self.manyObjectNames.count - index) * 10_000_000
            }
        }
        defer { withExtendedLifetime(fixture) {} }

        let summary = try await fixture.store.build(imagePath: Self.imageC, transformer: .default)

        #expect(summary.objectCount == Self.manyObjectNames.count)
        #expect(await fixture.store.corpus(for: Self.imageC)?.entries.map(\.object.name) == Self.manyObjectNames)
    }

    @Test("no more objects are printed at once than the printing width")
    func printingWidthBoundsConcurrency() async throws {
        let fixture = makeStore(printingWidth: 3) { builder in
            builder.objectNamesByImagePath[Self.imageC] = Self.manyObjectNames
            builder.delayPerObjectNanoseconds = 20_000_000
        }
        defer { withExtendedLifetime(fixture) {} }

        _ = try await fixture.store.build(imagePath: Self.imageC, transformer: .default)

        #expect(fixture.builder.maximumConcurrentPrintCount == 3)
    }

    @Test("progress counts finished prints up to the image's total")
    func progressCountsFinishedPrints() async throws {
        let fixture = makeStore(printingWidth: 4) { builder in
            builder.objectNamesByImagePath[Self.imageC] = Self.manyObjectNames
            builder.delayPerObjectNanoseconds = 5_000_000
        }
        defer { withExtendedLifetime(fixture) {} }
        let reports = ProgressReports()

        _ = try await fixture.store.build(imagePath: Self.imageC, transformer: .default) { progress in
            reports.append(progress)
        }

        let built = reports.all.map(\.built)
        #expect(built.first == 0)
        #expect(built.last == Self.manyObjectNames.count)
        #expect(built == built.sorted())
        #expect(reports.all.allSatisfy { $0.total == Self.manyObjectNames.count })
    }

    final class ProgressReports: @unchecked Sendable {
        private let lock = NSLock()
        private var reports: [RuntimeInterfaceCorpusBuildProgress] = []

        var all: [RuntimeInterfaceCorpusBuildProgress] {
            lock.withLock { reports }
        }

        func append(_ report: RuntimeInterfaceCorpusBuildProgress) {
            lock.withLock { reports.append(report) }
        }
    }

    /// Polls the store's coverage until `predicate` holds, for tests that
    /// need the queue in a particular shape before they act on it.
    private func waitForCoverage(
        of store: RuntimeInterfaceCorpusStore,
        timeout: TimeInterval = 10,
        where predicate: (RuntimeInterfaceCorpusCoverage) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(await store.coverage(indexedImagePaths: [])) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("the store never reached the expected coverage")
    }

    private func isBuilding(_ state: RuntimeInterfaceCorpusBuildState?) -> Bool {
        if case .building = state { return true }
        return false
    }

    /// Image A building, then B and C queued behind it, in that order.
    private func queueBehindRunningImage(_ fixture: Fixture, prioritizingC isPrioritized: Bool) async throws -> [Task<RuntimeInterfaceCorpusBuildSummary, any Swift.Error>] {
        let store = fixture.store
        let buildA = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
        try await waitForCoverage(of: store) { isBuilding($0.statesByImagePath[Self.imageA]) }
        let buildB = Task { try await store.build(imagePath: Self.imageB, transformer: .default) }
        try await waitForCoverage(of: store) { $0.statesByImagePath[Self.imageB] == .pending }
        let buildC = Task { try await store.build(imagePath: Self.imageC, transformer: .default, isPrioritized: isPrioritized) }
        try await waitForCoverage(of: store) { $0.statesByImagePath[Self.imageC] == .pending }
        return [buildA, buildB, buildC]
    }

    @Test("a prioritized image is built right after the image under way")
    func prioritizedImageBuiltNext() async throws {
        let fixture = makeStore {
            $0.objectNamesByImagePath[Self.imageC] = ["Delta"]
            $0.delayPerObjectNanoseconds = 100_000_000
        }
        defer { withExtendedLifetime(fixture) {} }
        let builds = try await queueBehindRunningImage(fixture, prioritizingC: false)

        await fixture.store.prioritize(imagePath: Self.imageC)

        for build in builds {
            _ = try await build.value
        }
        #expect(fixture.builder.printedObjectNames == ["Alpha", "Beta", "Delta", "Gamma"])
    }

    @Test("a build asked for with priority goes ahead of the images already waiting")
    func prioritizedRequestJumpsTheQueue() async throws {
        let fixture = makeStore {
            $0.objectNamesByImagePath[Self.imageC] = ["Delta"]
            $0.delayPerObjectNanoseconds = 100_000_000
        }
        defer { withExtendedLifetime(fixture) {} }
        let builds = try await queueBehindRunningImage(fixture, prioritizingC: true)

        for build in builds {
            _ = try await build.value
        }
        #expect(fixture.builder.printedObjectNames == ["Alpha", "Beta", "Delta", "Gamma"])
    }

    @Test("a search limited to some images reads only those")
    func scopedSearch() async throws {
        let fixture = makeStore()
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        _ = try await store.build(imagePath: Self.imageA, transformer: .default)
        _ = try await store.build(imagePath: Self.imageB, transformer: .default)

        var matches: [RuntimeInterfaceSearchMatch] = []
        let summary = try await store.searchInterfaces(RuntimeInterfaceSearchQuery(text: "member", imagePaths: [Self.imageB]), indexedImagePaths: []) { batch in
            matches += batch
        }
        #expect(matches.map(\.object.name) == ["Gamma"])
        #expect(summary.scannedImagePaths == [Self.imageB])

        var memberMatches: [RuntimeMemberMatch] = []
        _ = try await store.searchMembers(RuntimeMemberSearchQuery(text: "member", imagePaths: [Self.imageA]), indexedImagePaths: []) { batch in
            memberMatches += batch
        }
        #expect(memberMatches.map(\.object.name) == ["Alpha", "Beta"])
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

    /// The engine owns the store and can go away with work still queued — a source switch, a
    /// closed document, a test's engine at its end — before the eviction its `stop()` schedules
    /// arrives. The store used to hold it `unowned`, and the next queued build to start read it
    /// after it was gone, aborting the process.
    @Test("a build still queued when the builder goes away ends cancelled")
    func queuedBuildOutlivesBuilder() async throws {
        var builder: ScriptedBuilder? = ScriptedBuilder()
        builder?.objectNamesByImagePath = [Self.imageA: ["Alpha", "Beta"], Self.imageB: ["Gamma"]]
        builder?.delayPerObjectNanoseconds = 50_000_000
        let store = RuntimeInterfaceCorpusStore(builder: try #require(builder), printingWidth: 1)
        let buildA = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
        try await waitForCoverage(of: store) { isBuilding($0.statesByImagePath[Self.imageA]) }
        let buildB = Task { try await store.build(imagePath: Self.imageB, transformer: .default) }
        try await waitForCoverage(of: store) { $0.statesByImagePath[Self.imageB] == .pending }

        builder = nil

        // A was under way and may finish or not; B must not start on a builder that is gone.
        _ = try? await buildA.value
        await #expect(throws: CancellationError.self) { try await buildB.value }
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
