import Foundation
import Semantic
import Testing
@testable import RuntimeViewerCore

/// The corpus store with derived data: a build reads first and prints only
/// what it does not find, a print is written before its build settles, a
/// restore reads without printing, and whatever gives a build up while it
/// reads drops what the read brings back.
@Suite("RuntimeInterfaceCorpusStore with derived data", .serialized)
struct RuntimeInterfaceCorpusDerivedDataTests {
    typealias ScriptedBuilder = RuntimeInterfaceCorpusStoreTests.ScriptedBuilder
    typealias Gate = RuntimeInterfaceCorpusStoreTests.Gate

    private static let imageA = "/images/A"
    private static let imageB = "/images/B"

    private static let otherTransformer: Transformer.Configuration = {
        var transformer = Transformer.Configuration()
        transformer.objc.cType.isEnabled = true
        transformer.objc.cType.replacements[.double] = "CGFloat"
        return transformer
    }()

    /// A corpus store over a scripted builder and derived data in a
    /// directory of the test's own. The store holds its builder weakly, so
    /// the fixture keeps it.
    struct Fixture {
        let store: RuntimeInterfaceCorpusStore
        let builder: ScriptedBuilder
        let derivedData: RuntimeDerivedDataStore
        let directory: DerivedDataTestDirectory
    }

    private static func makeFixture(
        directory: DerivedDataTestDirectory? = nil,
        derivedData: RuntimeDerivedDataStore? = nil,
        readGate: Gate? = nil,
        _ configure: (ScriptedBuilder) -> Void = { _ in }
    ) throws -> Fixture {
        let directory = try directory ?? DerivedDataTestDirectory()
        let derivedData = derivedData ?? DerivedDataTestIdentities.store(in: directory)
        let builder = ScriptedBuilder()
        builder.objectNamesByImagePath = [imageA: ["Alpha", "Beta"], imageB: ["Gamma"]]
        configure(builder)
        let store = RuntimeInterfaceCorpusStore(builder: builder, derivedData: derivedData, printingWidth: 1, readStoredCorpus: { derivedData, imagePath, transformer in
            if let readGate {
                await readGate.wait()
            }
            return await RuntimeInterfaceCorpusStore.readStoredCorpus(from: derivedData, imagePath: imagePath, transformer: transformer)
        })
        return Fixture(store: store, builder: builder, derivedData: derivedData, directory: directory)
    }

    private static func containerExists(_ fixture: Fixture, imagePath: String, transformer: Transformer.Configuration = .default) throws -> Bool {
        let url = try #require(fixture.derivedData.containerURL(.interfaceCorpus, variant: RuntimeInterfaceCorpusSnapshot.variant(for: transformer), forImageAt: imagePath))
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Writing and the build path

    @Test("A build is written before it settles, and the next store reads it instead of printing")
    func buildWritesAndTheNextReads() async throws {
        let first = try Self.makeFixture()
        defer { withExtendedLifetime(first) {} }
        let summary = try await first.store.build(imagePath: Self.imageA, transformer: .default)
        #expect(try Self.containerExists(first, imagePath: Self.imageA), "written by the time the build returned")
        #expect(await first.store.restoredImage(for: Self.imageA) == nil, "printed, not read")

        let second = try Self.makeFixture(directory: first.directory, derivedData: first.derivedData)
        defer { withExtendedLifetime(second) {} }
        let readSummary = try await second.store.build(imagePath: Self.imageA, transformer: .default)
        #expect(readSummary == summary)
        #expect(second.builder.printedObjectNames.isEmpty)
        let restored = try #require(await second.store.restoredImage(for: Self.imageA))
        #expect(restored.summary == summary)
        #expect(restored.duration >= 0)
        let coverage = await second.store.coverage()
        #expect(coverage.statesByImagePath[Self.imageA] == .built(summary))
        #expect(coverage.restoredImagesByImagePath[Self.imageA] == restored)
        let firstEntries = try #require(await first.store.corpus(for: Self.imageA)).entries
        let secondEntries = try #require(await second.store.corpus(for: Self.imageA)).entries
        #expect(secondEntries.map(\.interface) == firstEntries.map(\.interface))
        #expect(secondEntries.map(\.members) == firstEntries.map(\.members))
    }

    @Test("A read that finds nothing goes on to print, and the print replaces nothing it should not")
    func missPrints() async throws {
        let fixture = try Self.makeFixture()
        defer { withExtendedLifetime(fixture) {} }
        _ = try await fixture.store.build(imagePath: Self.imageB, transformer: .default)
        #expect(fixture.builder.printedObjectNames == ["Gamma"])
        #expect(await fixture.store.coverage().restoredImagesByImagePath.isEmpty)
    }

    @Test("Another transformer reads nothing, prints, and its file replaces the old one")
    func otherTransformerPrints() async throws {
        let first = try Self.makeFixture()
        defer { withExtendedLifetime(first) {} }
        _ = try await first.store.build(imagePath: Self.imageA, transformer: .default)

        let second = try Self.makeFixture(directory: first.directory, derivedData: first.derivedData)
        defer { withExtendedLifetime(second) {} }
        _ = try await second.store.build(imagePath: Self.imageA, transformer: Self.otherTransformer)
        #expect(second.builder.printedObjectNames == ["Alpha", "Beta"])
        #expect(try Self.containerExists(second, imagePath: Self.imageA, transformer: Self.otherTransformer))
        #expect(try !Self.containerExists(second, imagePath: Self.imageA, transformer: .default))
    }

    @Test("An image outside the shared cache is neither read nor written")
    func imagesOutsideTheSharedCache() async throws {
        let directory = try DerivedDataTestDirectory()
        let derivedData = DerivedDataTestIdentities.store(in: directory, isSharedCacheImage: { $0 == Self.imageA })
        let fixture = try Self.makeFixture(directory: directory, derivedData: derivedData)
        defer { withExtendedLifetime(fixture) {} }
        _ = try await fixture.store.build(imagePath: Self.imageB, transformer: .default)
        #expect(fixture.derivedData.imageDirectory(forImageAt: Self.imageB) == nil)
        #expect(await fixture.store.restore(imagePaths: [Self.imageB], transformer: .default).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.location().rootURL.path))
    }

    @Test("A corpus that prints this process's addresses is searchable but not written")
    func processAddressesAreNotWritten() async throws {
        let fixture = try Self.makeFixture { builder in
            builder.interfaceTextByObjectName["Gamma"] = "var body: opaque type symbolic reference 0x1A2B3C"
        }
        defer { withExtendedLifetime(fixture) {} }
        _ = try await fixture.store.build(imagePath: Self.imageB, transformer: .default)
        #expect(await fixture.store.corpus(for: Self.imageB) != nil)
        #expect(try !Self.containerExists(fixture, imagePath: Self.imageB))
    }

    // MARK: - Restoring

    @Test("A restore reads what is stored without printing, and leaves the rest alone")
    func restoreReadsWithoutPrinting() async throws {
        let first = try Self.makeFixture()
        defer { withExtendedLifetime(first) {} }
        let summary = try await first.store.build(imagePath: Self.imageA, transformer: .default)

        let second = try Self.makeFixture(directory: first.directory, derivedData: first.derivedData)
        defer { withExtendedLifetime(second) {} }
        let restored = await second.store.restore(imagePaths: [Self.imageA, Self.imageB], transformer: .default)
        #expect(Set(restored.keys) == [Self.imageA])
        #expect(restored[Self.imageA]?.summary == summary)
        #expect(second.builder.printedObjectNames.isEmpty)
        let coverage = await second.store.coverage()
        #expect(coverage.statesByImagePath == [Self.imageA: .built(summary)], "nothing left pending for B")

        // Building it now prints nothing, and a second restore reports the
        // same read.
        #expect(try await second.store.build(imagePath: Self.imageA, transformer: .default) == summary)
        #expect(second.builder.printedObjectNames.isEmpty)
        #expect(await second.store.restore(imagePaths: [Self.imageA], transformer: .default) == restored)
    }

    @Test("A restore takes a waiting build out of the queue, and that build's subscribers get the corpus read")
    func restoreTakesAQueuedBuild() async throws {
        let writer = try Self.makeFixture()
        defer { withExtendedLifetime(writer) {} }
        let printGate = Gate()
        let reader = try Self.makeFixture(directory: writer.directory, derivedData: writer.derivedData) { builder in
            builder.printGate = printGate
        }
        defer { withExtendedLifetime(reader) {} }

        // B prints, held at the gate; A, with nothing stored yet, queues behind it.
        let buildB = Task { try await reader.store.build(imagePath: Self.imageB, transformer: .default) }
        try await printGate.waitForWaiters(1)
        let buildA = Task { try await reader.store.build(imagePath: Self.imageA, transformer: .default) }
        try await Self.waitUntilPending(Self.imageA, in: reader.store)

        // Meanwhile another process writes A; the restore finds it.
        let summary = try await writer.store.build(imagePath: Self.imageA, transformer: .default)
        let restored = await reader.store.restore(imagePaths: [Self.imageA], transformer: .default)
        #expect(restored[Self.imageA]?.summary == summary)
        #expect(try await buildA.value == summary)

        printGate.open()
        _ = try await buildB.value
        #expect(reader.builder.printedObjectNames == ["Gamma"], "A was read, not printed")
    }

    @Test("A restore finding nothing for a waiting build puts it back where it was")
    func restoreMissRequeues() async throws {
        let printGate = Gate()
        let fixture = try Self.makeFixture { builder in
            builder.objectNamesByImagePath["/images/C"] = ["Delta"]
            builder.printGate = printGate
        }
        defer { withExtendedLifetime(fixture) {} }
        let buildB = Task { try await fixture.store.build(imagePath: Self.imageB, transformer: .default) }
        try await printGate.waitForWaiters(1)
        let buildA = Task { try await fixture.store.build(imagePath: Self.imageA, transformer: .default) }
        try await Self.waitUntilPending(Self.imageA, in: fixture.store)
        let buildC = Task { try await fixture.store.build(imagePath: "/images/C", transformer: .default) }
        try await Self.waitUntilPending("/images/C", in: fixture.store)

        #expect(await fixture.store.restore(imagePaths: [Self.imageA], transformer: .default).isEmpty)
        printGate.open()
        _ = try await (buildA.value, buildB.value, buildC.value)
        #expect(fixture.builder.printedObjectNames == ["Gamma", "Alpha", "Beta", "Delta"], "A kept its place ahead of C")
    }

    @Test("A restore leaves an image being printed to the printer")
    func restoreLeavesAPrintAlone() async throws {
        let printGate = Gate()
        let fixture = try Self.makeFixture { builder in
            builder.printGate = printGate
        }
        defer { withExtendedLifetime(fixture) {} }
        let build = Task { try await fixture.store.build(imagePath: Self.imageA, transformer: .default) }
        try await printGate.waitForWaiters(1)
        #expect(await fixture.store.restore(imagePaths: [Self.imageA], transformer: .default).isEmpty)
        printGate.open()
        _ = try await build.value
        #expect(fixture.builder.printedObjectNames == ["Alpha", "Beta"])
    }

    // MARK: - Giving a read up

    enum GiveUp: String, CaseIterable, CustomTestStringConvertible {
        case cancellingTheRequest
        case evictingTheImage
        case evictingEverything
        case askingWithAnotherTransformer

        var testDescription: String { rawValue }
    }

    @Test("Whatever gives a build up while it reads drops what the read brings back", arguments: GiveUp.allCases)
    func givingUpAReadDropsIt(_ giveUp: GiveUp) async throws {
        let writer = try Self.makeFixture()
        defer { withExtendedLifetime(writer) {} }
        _ = try await writer.store.build(imagePath: Self.imageA, transformer: .default)

        let readGate = Gate()
        let reader = try Self.makeFixture(directory: writer.directory, derivedData: writer.derivedData, readGate: readGate)
        defer { withExtendedLifetime(reader) {} }
        let build = Task { try await reader.store.build(imagePath: Self.imageA, transformer: .default) }
        try await readGate.waitForWaiters(1)

        var otherBuild: Task<RuntimeInterfaceCorpusBuildSummary, any Swift.Error>?
        switch giveUp {
        case .cancellingTheRequest:
            build.cancel()
        case .evictingTheImage:
            await reader.store.evict(imagePath: Self.imageA)
        case .evictingEverything:
            await reader.store.evictAll()
        case .askingWithAnotherTransformer:
            otherBuild = Task { try await reader.store.build(imagePath: Self.imageA, transformer: Self.otherTransformer) }
            try await readGate.waitForWaiters(2)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await build.value
        }
        readGate.open()

        if let otherBuild {
            // The new configuration's own read finds nothing and prints.
            _ = try await otherBuild.value
            #expect(await reader.store.corpus(for: Self.imageA)?.transformer == Self.otherTransformer)
            #expect(reader.builder.printedObjectNames == ["Alpha", "Beta"])
        } else {
            try await Task.sleep(nanoseconds: 200_000_000)
            #expect(await reader.store.corpus(for: Self.imageA) == nil, "the read's corpus was not put back")
            #expect(await reader.store.coverage().statesByImagePath.isEmpty)
            #expect(reader.builder.printedObjectNames.isEmpty)
        }
    }

    @Test("A restore waiting on a read is told nothing when the build is given up, and a cancelled one withdraws")
    func restoreGivenUp() async throws {
        let writer = try Self.makeFixture()
        defer { withExtendedLifetime(writer) {} }
        _ = try await writer.store.build(imagePath: Self.imageA, transformer: .default)
        let readGate = Gate()
        let reader = try Self.makeFixture(directory: writer.directory, derivedData: writer.derivedData, readGate: readGate)
        defer { withExtendedLifetime(reader) {} }

        let evicted = Task { await reader.store.restore(imagePaths: [Self.imageA], transformer: .default) }
        try await readGate.waitForWaiters(1)
        await reader.store.evict(imagePath: Self.imageA)
        #expect(await evicted.value.isEmpty)

        let cancelled = Task { await reader.store.restore(imagePaths: [Self.imageA], transformer: .default) }
        try await readGate.waitForWaiters(2)
        cancelled.cancel()
        #expect(await cancelled.value.isEmpty)
        readGate.open()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await reader.store.corpus(for: Self.imageA) == nil)
    }

    @Test("A build joining a restore's read is settled by it, and prints if it finds nothing")
    func buildJoinsARestoreRead() async throws {
        let readGate = Gate()
        let fixture = try Self.makeFixture(readGate: readGate)
        defer { withExtendedLifetime(fixture) {} }
        let restore = Task { await fixture.store.restore(imagePaths: [Self.imageA], transformer: .default) }
        try await readGate.waitForWaiters(1)
        let build = Task { try await fixture.store.build(imagePath: Self.imageA, transformer: .default) }
        try await Task.sleep(nanoseconds: 50_000_000)
        readGate.open()
        #expect(await restore.value.isEmpty)
        _ = try await build.value
        #expect(fixture.builder.printedObjectNames == ["Alpha", "Beta"])
    }

    // MARK: - Coverage

    @Test("A restored image leaves the coverage's restored list when its corpus is evicted or printed again")
    func restoredListFollowsTheCorpus() async throws {
        let writer = try Self.makeFixture()
        defer { withExtendedLifetime(writer) {} }
        _ = try await writer.store.build(imagePath: Self.imageA, transformer: .default)
        let reader = try Self.makeFixture(directory: writer.directory, derivedData: writer.derivedData)
        defer { withExtendedLifetime(reader) {} }

        _ = await reader.store.restore(imagePaths: [Self.imageA], transformer: .default)
        #expect(await reader.store.coverage().restoredImagesByImagePath.keys.sorted() == [Self.imageA])
        await reader.store.evict(imagePath: Self.imageA)
        #expect(await reader.store.coverage().restoredImagesByImagePath.isEmpty)

        _ = await reader.store.restore(imagePaths: [Self.imageA], transformer: .default)
        _ = try await reader.store.build(imagePath: Self.imageA, transformer: Self.otherTransformer)
        #expect(await reader.store.coverage().restoredImagesByImagePath.isEmpty, "printed again under the new configuration")
    }

    @Test("Coverage from a peer that predates the restored list decodes, with an empty one")
    func oldCoverageDecodes() throws {
        let coverage = RuntimeInterfaceCorpusCoverage(
            statesByImagePath: [Self.imageA: .built(.init(objectCount: 2, skippedCount: 0, byteCount: 100))],
            residentByteCount: 100,
            residentByteLimit: 1000,
            restoredImagesByImagePath: [Self.imageA: .init(summary: .init(objectCount: 2, skippedCount: 0, byteCount: 100), duration: 0.25)]
        )
        let data = try JSONEncoder().encode(coverage)
        #expect(try JSONDecoder().decode(RuntimeInterfaceCorpusCoverage.self, from: data) == coverage)

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["restoredImagesByImagePath"] = nil
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RuntimeInterfaceCorpusCoverage.self, from: oldData)
        #expect(decoded.statesByImagePath == coverage.statesByImagePath)
        #expect(decoded.restoredImagesByImagePath.isEmpty)
    }

    // MARK: - Helpers

    /// Returns once the image's build waits in the queue, past its read.
    private static func waitUntilPending(_ imagePath: String, in store: RuntimeInterfaceCorpusStore, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await store.isQueued(imagePath: imagePath)) {
            guard Date() < deadline else {
                Issue.record("\(imagePath) never queued")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
