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
        /// Replaces the scripted interface of the objects it names with this
        /// text alone, no members.
        var interfaceTextByObjectName: [String: String] = [:]
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
            if let interfaceText = interfaceTextByObjectName[object.name] {
                return RuntimeInterfaceCorpusPrint(
                    object: object,
                    interface: SemanticString { Standard(interfaceText) }.frozen(),
                    visibilityRegions: .empty,
                    members: [],
                    nestedDefinitionRanges: []
                )
            }
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

        /// Returns once `count` callers wait here, so a test acts while that
        /// work is held — a state that lasts until the test opens the gate,
        /// however long the machine takes to get there.
        func waitForWaiters(_ count: Int = 1, timeout: TimeInterval = 10) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while waiterCount < count {
                guard Date() < deadline else {
                    Issue.record("\(count) callers never waited at the gate")
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

    private func makeStore(
        printingWidth: Int = 1,
        regularExpressionTimeLimit: TimeInterval = RuntimeInterfaceTextMatcher.RegularExpressionBudget.defaultTimeLimit,
        _ configure: (ScriptedBuilder) -> Void = { _ in }
    ) -> Fixture {
        let builder = ScriptedBuilder()
        builder.objectNamesByImagePath = [Self.imageA: ["Alpha", "Beta"], Self.imageB: ["Gamma"]]
        configure(builder)
        let store = RuntimeInterfaceCorpusStore(builder: builder, printingWidth: printingWidth, regularExpressionTimeLimit: regularExpressionTimeLimit)
        return Fixture(store: store, builder: builder)
    }

    /// Long enough that `(a+)+\(` takes seconds to give up on it: every way
    /// of splitting the run is tried before the missing `(` is accepted.
    private static let slowEntryText = "var " + String(repeating: "a", count: 26) + ": Int"

    /// A's `memberAlpha` matches at once; C's run of a's then keeps the
    /// regular expression engine busy for seconds. A's batch arriving says
    /// the scan is under way and about to read C.
    private static let alphaThenSlowQuery = RuntimeInterfaceSearchQuery(text: #"memberAlpha|(a+)+\("#, matchMode: .regularExpression, isCaseSensitive: true)

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.withLock { value }
        }

        func set() {
            lock.withLock { value = true }
        }

        /// Returns once the flag is set. A set flag stays set, so polling
        /// cannot miss it.
        func waitUntilSet(timeout: TimeInterval = 10) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !isSet {
                guard Date() < deadline else {
                    Issue.record("the flag was never set")
                    return
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
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
        let printGate = Gate()
        let fixture = makeStore(printingWidth: 3) { builder in
            builder.objectNamesByImagePath[Self.imageC] = Self.manyObjectNames
            builder.printGate = printGate
        }
        defer { withExtendedLifetime(fixture) {} }
        let build = Task { try await fixture.store.build(imagePath: Self.imageC, transformer: .default) }

        // Every print waits at the gate, so the width is reached for certain
        // — and a fourth print could only start beside them.
        try await printGate.waitForWaiters(3)
        printGate.open()
        _ = try await build.value

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
            if predicate(await store.coverage()) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("the store never reached the expected coverage")
    }

    /// Image A building, held at its first print by `printGate` until the
    /// test opens it, then B and C queued behind it, in that order. The
    /// builder must hold its prints at `printGate`. A build kept going by a
    /// delay instead could finish before a loaded machine had seen it run.
    private func queueBehindRunningImage(_ fixture: Fixture, printGate: Gate, prioritizingC isPrioritized: Bool) async throws -> [Task<RuntimeInterfaceCorpusBuildSummary, any Swift.Error>] {
        let store = fixture.store
        let buildA = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
        try await printGate.waitForWaiters()
        let buildB = Task { try await store.build(imagePath: Self.imageB, transformer: .default) }
        try await waitForCoverage(of: store) { $0.statesByImagePath[Self.imageB] == .pending }
        let buildC = Task { try await store.build(imagePath: Self.imageC, transformer: .default, isPrioritized: isPrioritized) }
        try await waitForCoverage(of: store) { $0.statesByImagePath[Self.imageC] == .pending }
        return [buildA, buildB, buildC]
    }

    @Test("a prioritized image is built right after the image under way")
    func prioritizedImageBuiltNext() async throws {
        let printGate = Gate()
        let fixture = makeStore {
            $0.objectNamesByImagePath[Self.imageC] = ["Delta"]
            $0.printGate = printGate
        }
        defer { withExtendedLifetime(fixture) {} }
        let builds = try await queueBehindRunningImage(fixture, printGate: printGate, prioritizingC: false)

        await fixture.store.prioritize(imagePath: Self.imageC)
        printGate.open()

        for build in builds {
            _ = try await build.value
        }
        #expect(fixture.builder.printedObjectNames == ["Alpha", "Beta", "Delta", "Gamma"])
    }

    @Test("a build asked for with priority goes ahead of the images already waiting")
    func prioritizedRequestJumpsTheQueue() async throws {
        let printGate = Gate()
        let fixture = makeStore {
            $0.objectNamesByImagePath[Self.imageC] = ["Delta"]
            $0.printGate = printGate
        }
        defer { withExtendedLifetime(fixture) {} }
        let builds = try await queueBehindRunningImage(fixture, printGate: printGate, prioritizingC: true)
        printGate.open()

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

    /// The scan ran on the store's actor, so a regular expression that
    /// backtracks without end held every build, coverage query and search of
    /// the engine behind it.
    @Test("the store answers other calls while a search scans")
    func storeAnswersWhileSearching() async throws {
        let fixture = makeStore { builder in
            builder.objectNamesByImagePath[Self.imageC] = ["Slow"]
            builder.interfaceTextByObjectName["Slow"] = Self.slowEntryText
        }
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        _ = try await store.build(imagePath: Self.imageA, transformer: .default)
        _ = try await store.build(imagePath: Self.imageC, transformer: .default)
        let firstBatchArrived = Flag()
        let searchFinished = Flag()
        let search = Task {
            defer { searchFinished.set() }
            return try await store.searchInterfaces(Self.alphaThenSlowQuery, indexedImagePaths: []) { _ in
                firstBatchArrived.set()
            }
        }
        try await firstBatchArrived.waitUntilSet()

        _ = await store.coverage()

        #expect(!searchFinished.isSet, "coverage waited for the whole scan")
        search.cancel()
        _ = try? await search.value
    }

    @Test("a search stops inside an image once it is cancelled")
    func searchStopsInsideAnImage() async throws {
        let fixture = makeStore { builder in
            builder.objectNamesByImagePath[Self.imageC] = ["Slow"]
            builder.interfaceTextByObjectName["Slow"] = Self.slowEntryText
        }
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        _ = try await store.build(imagePath: Self.imageA, transformer: .default)
        _ = try await store.build(imagePath: Self.imageC, transformer: .default)
        let firstBatchArrived = Flag()
        let search = Task {
            try await store.searchInterfaces(Self.alphaThenSlowQuery, indexedImagePaths: []) { _ in
                firstBatchArrived.set()
            }
        }
        try await firstBatchArrived.waitUntilSet()

        search.cancel()

        await #expect(throws: CancellationError.self) { try await search.value }
    }

    @Test("a search whose regular expression spends its budget keeps what it found and says why it stopped")
    func searchReportsWhyItStopped() async throws {
        // Far more than A's few lines take even on a loaded machine, far less
        // than C's run of a's.
        let fixture = makeStore(regularExpressionTimeLimit: 0.5) { builder in
            builder.objectNamesByImagePath[Self.imageC] = ["Slow"]
            builder.interfaceTextByObjectName["Slow"] = Self.slowEntryText
        }
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        _ = try await store.build(imagePath: Self.imageA, transformer: .default)
        _ = try await store.build(imagePath: Self.imageC, transformer: .default)
        let batches = MatchBatches<RuntimeInterfaceSearchMatch>()

        let summary = try await store.searchInterfaces(Self.alphaThenSlowQuery, indexedImagePaths: []) { batch in
            batches.append(batch)
        }

        #expect(batches.all.flatMap { $0 }.map(\.object.name) == ["Alpha"])
        #expect(summary.stopReason == .regularExpressionTooExpensive)
        #expect(summary.scannedImagePaths == [Self.imageA, Self.imageC])
    }

    @Test("a member search whose regular expression spends its budget says why it stopped")
    func memberSearchReportsWhyItStopped() async throws {
        let fixture = makeStore(regularExpressionTimeLimit: 0)
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        _ = try await store.build(imagePath: Self.imageA, transformer: .default)

        let summary = try await store.searchMembers(RuntimeMemberSearchQuery(text: "^member", matchMode: .regularExpression), indexedImagePaths: []) { _ in }

        #expect(summary.stopReason == .regularExpressionTooExpensive)
    }

    /// Batches delivered to a search's progress handler, which is
    /// `@Sendable`.
    final class MatchBatches<Match: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[Match]] = []

        var all: [[Match]] {
            lock.withLock { batches }
        }

        func append(_ batch: [Match]) {
            lock.withLock { batches.append(batch) }
        }
    }

    /// The member search under Generation Options locates each member again
    /// in the projected text; no other test reaches that path.
    @Test("a member under options is located on its line of the projected text")
    func memberLocatedInProjection() {
        // Line 2 is hidden under the options, so `shown` moves from line 3 to
        // line 2. `Comment` writes the `// ` itself.
        let interface = SemanticString {
            Keyword("struct")
            Standard(" S {\n")
            Standard("    ")
            Comment("hidden\n")
            Standard("    ")
            Keyword("var")
            Standard(" ")
            Variable("shown")
            Standard(": Int\n}")
        }.frozen()
        // "struct S {\n" is 11 bytes; the comment span, newline included, is 14.
        let regions = VisibilityRegionTable(
            regions: [VisibilityRegionTable.Region(utf8Offset: 11, utf8Length: 14, conditionIndex: 0)],
            conditions: [.enabled("test.showsComments")]
        )
        let entry = RuntimeInterfaceCorpusEntry(
            object: RuntimeObject(name: "S", displayName: "S", kind: .swift(.type(.struct)), imagePath: Self.imageA, children: []),
            interface: interface,
            visibilityRegions: regions,
            members: [RuntimeMemberDeclaration(name: "shown", kind: .swiftVariable, isStatic: false, declarationText: "shown", lineNumber: 3)]
        )
        let projection = regions.projection(of: interface) { _ in false }
        #expect(interface.text == "struct S {\n    // hidden\n    var shown: Int\n}")
        #expect(projection.text.text == "struct S {\n    var shown: Int\n}")

        let shown = entry.member(at: 0, in: projection, projectedLineTable: RuntimeInterfaceLineTable(projection.text.text))

        #expect(shown?.lineNumber == 2)
        #expect(shown?.declarationText == "var shown: Int")
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
        #expect(await store.coverage().statesByImagePath[Self.imageA]?.isBuilt == true)
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
        guard case .failed = await store.coverage().statesByImagePath[Self.imageA] else {
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
        let printGate = Gate()
        var builder: ScriptedBuilder? = ScriptedBuilder()
        builder?.objectNamesByImagePath = [Self.imageA: ["Alpha", "Beta"], Self.imageB: ["Gamma"]]
        builder?.printGate = printGate
        let store = RuntimeInterfaceCorpusStore(builder: try #require(builder), printingWidth: 1)
        let buildA = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
        try await printGate.waitForWaiters()
        let buildB = Task { try await store.build(imagePath: Self.imageB, transformer: .default) }
        try await waitForCoverage(of: store) { $0.statesByImagePath[Self.imageB] == .pending }

        // A's build holds the builder until it ends; then nothing does.
        builder = nil
        printGate.open()

        // A was under way and may finish or not; B must not start on a builder that is gone.
        _ = try? await buildA.value
        await #expect(throws: CancellationError.self) { try await buildB.value }
    }

    /// Polls until `count` requests wait on the image's build. Once made, a
    /// subscription stays until the test acts, so polling cannot miss it.
    private func waitForSubscribers(_ count: Int, of imagePath: String, in store: RuntimeInterfaceCorpusStore, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await store.subscriberCount(for: imagePath) >= count { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("the build of \(imagePath) never had \(count) subscribers")
    }

    @Test("cancelling one of two subscribers leaves the build running")
    func subscriptionRefcount() async throws {
        let printGate = Gate()
        let fixture = makeStore { $0.printGate = printGate }
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let first = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
        try await printGate.waitForWaiters()
        let second = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
        try await waitForSubscribers(2, of: Self.imageA, in: store)

        first.cancel()

        await #expect(throws: CancellationError.self) { try await first.value }
        printGate.open()
        let summary = try await second.value
        #expect(summary.objectCount == 2)
        // One build served both.
        #expect(fixture.builder.printedObjectNames == ["Alpha", "Beta"])
    }

    @Test("cancelling the last subscriber cancels the build and leaves nothing behind")
    func lastSubscriberCancels() async throws {
        let printGate = Gate()
        let fixture = makeStore { $0.printGate = printGate }
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let only = Task { try await store.build(imagePath: Self.imageA, transformer: .default) }
        try await printGate.waitForWaiters()

        only.cancel()

        await #expect(throws: CancellationError.self) { try await only.value }
        #expect(await store.coverage().statesByImagePath[Self.imageA] == nil)
        printGate.open()
        // B starts once A's task has handed the slot back, so by now A has
        // stopped: the print under way when it was cancelled finished, and
        // no other print began.
        _ = try await store.build(imagePath: Self.imageB, transformer: .default)
        #expect(fixture.builder.printedObjectNames == ["Alpha", "Gamma"])
        #expect(await store.corpus(for: Self.imageA) == nil)
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
        try await gate.waitForWaiters()

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
        try await gate.waitForWaiters()

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
        try await assemblyGate.waitForWaiters()

        await store.evict(imagePath: Self.imageA)
        assemblyGate.open()

        await #expect(throws: CancellationError.self) { try await buildA.value }
        // B starts only once A's task has handed the slot back, so by now A's
        // outcome has been handled.
        _ = try await store.build(imagePath: Self.imageB, transformer: .default)
        #expect(await store.corpus(for: Self.imageA) == nil)
        #expect(await store.coverage().statesByImagePath[Self.imageA] == nil)
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

    /// Once the result limit is reached a search only counts, and a count
    /// needs no line table — nor, over every kind, a span table. Alpha, Beta
    /// and Gamma each have one hit of `member`; only Alpha's is collected.
    @Test("a search past its result limit builds no tables for the hits it only counts", arguments: [
        (RuntimeInterfaceSearchScope.all, 1, 1),
        (RuntimeInterfaceSearchScope.symbolsOnly, 1, 3),
    ])
    func countingPastTheLimitBuildsNoTables(scope: RuntimeInterfaceSearchScope, expectedLineTableCount: Int, expectedSpanKindTableCount: Int) async throws {
        let fixture = makeStore()
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        _ = try await store.build(imagePath: Self.imageA, transformer: .default)
        _ = try await store.build(imagePath: Self.imageB, transformer: .default)
        let workLog = RuntimeInterfaceSearchWorkLog()

        let summary = try await RuntimeInterfaceSearchWorkLog.$current.withValue(workLog) {
            try await store.searchInterfaces(RuntimeInterfaceSearchQuery(text: "member", scope: scope, resultLimit: 1), indexedImagePaths: []) { _ in }
        }

        #expect(summary.totalMatchCount == 3)
        #expect(workLog.count(of: .lineTable) == expectedLineTableCount)
        #expect(workLog.count(of: .spanKindTable) == expectedSpanKindTableCount)
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
