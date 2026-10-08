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
        /// Holds every print until the test opens it.
        var printGate: Gate?
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

        func corpusPrints(of family: [RuntimeObject], transformer: Transformer.Configuration) async throws -> [RuntimeInterfaceCorpusPrintOutcome] {
            var outcomes: [RuntimeInterfaceCorpusPrintOutcome] = []
            for object in family {
                do {
                    outcomes.append(.printed(try await corpusPrint(for: object)))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    outcomes.append(.failed("\(error)"))
                }
            }
            return outcomes
        }

        private func corpusPrint(for object: RuntimeObject) async throws -> RuntimeInterfaceCorpusPrint {
            lock.withLock {
                concurrentPrintCount += 1
                maximumConcurrentPrintCount = max(maximumConcurrentPrintCount, concurrentPrintCount)
            }
            defer { lock.withLock { concurrentPrintCount -= 1 } }
            if let printGate {
                await printGate.wait()
            }
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
                nestedDefinitionRanges: []
            )
        }
    }

    enum ScriptedError: Swift.Error {
        case imageFailed(String)
        case objectFailed(String)
    }

    /// Holds whoever waits at it until the test opens it, and ignores
    /// cancellation meanwhile — as MachOSwiftSection's printing does, which
    /// has no cancellation point.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var waiterCount: Int {
            lock.withLock { waiters.count }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let resumesNow = lock.withLock {
                    if isOpen { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumesNow {
                    continuation.resume()
                }
            }
        }

        func open() {
            let releasedWaiters = lock.withLock {
                isOpen = true
                defer { waiters.removeAll() }
                return waiters
            }
            for waiter in releasedWaiters {
                waiter.resume()
            }
        }

        /// Returns once someone waits here, so a test acts while that work
        /// is in flight.
        func waitForWaiter(timeout: TimeInterval = 10) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while waiterCount == 0 {
                guard Date() < deadline else {
                    Issue.record("nothing ever waited at the gate")
                    return
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
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

    @Test("an object and the objects nested in it print as one family where the listing keeps them together")
    func familiesFollowTheListing() {
        let grandchild = RuntimeObject(name: "Grandchild", displayName: "Parent.Child.Grandchild", kind: .swift(.type(.struct)), imagePath: Self.imageA, children: [])
        let child = RuntimeObject(name: "Child", displayName: "Parent.Child", kind: .swift(.type(.struct)), imagePath: Self.imageA, children: [grandchild])
        let parent = RuntimeObject(name: "Parent", displayName: "Parent", kind: .swift(.type(.struct)), imagePath: Self.imageA, children: [child])
        let other = RuntimeObject(name: "Other", displayName: "Other", kind: .swift(.type(.struct)), imagePath: Self.imageA, children: [])

        #expect(RuntimeInterfaceCorpusStore.families(in: [parent, child, grandchild, other]) == [0 ..< 3, 3 ..< 4])
        // A listing that splits a family prints the objects it cannot keep
        // with their parent one by one.
        #expect(RuntimeInterfaceCorpusStore.families(in: [parent, other, child, grandchild]) == [0 ..< 1, 1 ..< 2, 2 ..< 4])
    }

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

    @Test("a search limited to some images counts only those among the images not yet searchable")
    func scopedSearchReportsItsOwnUnbuiltImages() async throws {
        let fixture = makeStore()
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        _ = try await store.build(imagePath: Self.imageA, transformer: .default)
        let indexedImagePaths: Set<String> = [Self.imageA, Self.imageB, Self.imageC]

        let textSummary = try await store.searchInterfaces(RuntimeInterfaceSearchQuery(text: "member", imagePaths: [Self.imageA, Self.imageB]), indexedImagePaths: indexedImagePaths) { _ in }
        let memberSummary = try await store.searchMembers(RuntimeMemberSearchQuery(text: "member", imagePaths: [Self.imageA, Self.imageB]), indexedImagePaths: indexedImagePaths) { _ in }

        #expect(textSummary.unbuiltIndexedImagePaths == [Self.imageB])
        #expect(memberSummary.unbuiltIndexedImagePaths == [Self.imageB])
    }

    /// The scripted members are `memberAlpha`, `memberBeta` and `memberGamma`.
    @Test("a member search matches names with the text search's match styles", arguments: [
        (RuntimeMemberSearchQuery(text: "beta", matchMode: .matchingWord), [String]()),
        (RuntimeMemberSearchQuery(text: "memberbeta", matchMode: .matchingWord), ["memberBeta"]),
        (RuntimeMemberSearchQuery(text: "alpha", matchMode: .startingWith), []),
        (RuntimeMemberSearchQuery(text: "member", matchMode: .startingWith), ["memberAlpha", "memberBeta", "memberGamma"]),
        (RuntimeMemberSearchQuery(text: "Gamma", matchMode: .endingWith, isCaseSensitive: true), ["memberGamma"]),
        (RuntimeMemberSearchQuery(text: "member", matchMode: .endingWith), []),
        (RuntimeMemberSearchQuery(text: "^member(Alpha|Gamma)$", matchMode: .regularExpression, isCaseSensitive: true), ["memberAlpha", "memberGamma"]),
    ])
    func memberMatchStyles(query: RuntimeMemberSearchQuery, expectedNames: [String]) async throws {
        let fixture = makeStore()
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        _ = try await store.build(imagePath: Self.imageA, transformer: .default)
        _ = try await store.build(imagePath: Self.imageB, transformer: .default)

        var names: [String] = []
        _ = try await store.searchMembers(query, indexedImagePaths: []) { batch in
            names += batch.map(\.member.name)
        }

        #expect(names == expectedNames)
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

    @Test("a search with an invalid regular expression fails with a readable reason")
    func invalidRegularExpressionSearchFailsReadably() async throws {
        let fixture = makeStore()
        defer { withExtendedLifetime(fixture) {} }
        _ = try await fixture.store.build(imagePath: Self.imageA, transformer: .default)

        do {
            _ = try await fixture.store.searchInterfaces(RuntimeInterfaceSearchQuery(text: "(", matchMode: .regularExpression), indexedImagePaths: []) { _ in }
            Issue.record("the search should have failed")
        } catch {
            #expect(error.localizedDescription == "“(” is not a valid regular expression.")
        }
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

    /// A running build cannot be interrupted while a print is in flight, so
    /// cancelling it used to leave it in place, accepting subscribers: a
    /// request that came next joined it and was cancelled with it.
    @Test("a request after the running build of its image was cancelled starts a build of its own")
    func requestAfterCancellingRunningBuildStartsAfresh() async throws {
        let gate = Gate()
        let fixture = makeStore { $0.printGate = gate }
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let first = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
        try await gate.waitForWaiter()

        await store.evict(imagePath: Self.imageA)
        let second = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
        // The first print is still held: the cancelled build keeps the slot,
        // and the second request waits behind it with a build of its own.
        try await waitForCoverage(of: store) { $0.statesByImagePath[Self.imageA] == .pending }
        gate.open()

        await #expect(throws: CancellationError.self) { try await first.value }
        let summary = try await second.value
        #expect(summary.objectCount == 2)
    }

    @Test("a different transformer asked for while the image prints gets a build of its own")
    func transformerChangeWhilePrintingRebuilds() async throws {
        let gate = Gate()
        let fixture = makeStore { $0.printGate = gate }
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        var changed = Transformer.Configuration.default
        changed.objc.cType.isEnabled.toggle()
        let first = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
        try await gate.waitForWaiter()

        let second = Task { try await store.build(imagePath: Self.imageA, transformer: changed) }
        try await waitForCoverage(of: store) { $0.statesByImagePath[Self.imageA] == .pending }
        gate.open()

        await #expect(throws: CancellationError.self) { try await first.value }
        _ = try await second.value
        #expect(await store.corpus(for: Self.imageA)?.transformer == changed)
    }

    /// The only cancellation check came before the assembly, so an eviction
    /// that arrived during it was stored as built anyway — stale entries, or
    /// a corpus back in memory right after the user turned corpora off.
    @Test("a build evicted while its entries are assembled leaves nothing behind")
    func evictionDuringAssemblyLeavesNothing() async throws {
        let assemblyGate = Gate()
        let builder = ScriptedBuilder()
        builder.objectNamesByImagePath = [Self.imageA: ["Alpha", "Beta"], Self.imageB: ["Gamma"]]
        defer { withExtendedLifetime(builder) {} }
        let store = RuntimeInterfaceCorpusStore(builder: builder, printingWidth: 1) { prints in
            await assemblyGate.wait()
            return RuntimeInterfaceCorpusAssembly.entries(from: prints)
        }
        let buildA = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
        try await assemblyGate.waitForWaiter()

        await store.evict(imagePath: Self.imageA)
        assemblyGate.open()

        await #expect(throws: CancellationError.self) { try await buildA.value }
        // B starts only once A's task has handed the slot back, so by now A's
        // outcome has been handled.
        _ = try await store.build(imagePath: Self.imageB, transformer: .default)
        #expect(await store.corpus(for: Self.imageA) == nil)
        #expect(await store.coverage(indexedImagePaths: []).statesByImagePath[Self.imageA] == nil)
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
