import Foundation
import Testing
@testable import RuntimeViewerCore

/// Derived data against real images: libobjc's and Foundation's corpora
/// read back entry for entry, and an engine that restores what another one
/// printed answers searches the same way.
@Suite("Derived data with real corpora", .serialized)
struct RuntimeInterfaceCorpusDerivedDataEngineTests {
    private static let libobjcPath = "/usr/lib/libobjc.A.dylib"
    private static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
    private static let swiftUIPath = "/System/Library/Frameworks/SwiftUI.framework/SwiftUI"
    private static let appKitPath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"

    private static func makeEngine(_ label: String, loading imagePaths: [String]) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: "test-derived-data-" + label)
        try await engine.connect()
        for imagePath in imagePaths {
            try await engine.loadImage(at: imagePath)
        }
        return engine
    }

    private static func header(for imagePath: String) -> RuntimeDerivedDataContainer.Header {
        RuntimeDerivedDataContainer.Header(
            kind: RuntimeDerivedDataKind.interfaceCorpus.rawValue,
            variant: RuntimeInterfaceCorpusSnapshot.variant(for: .default),
            imagePath: imagePath,
            systemDirectoryName: DerivedDataTestIdentities.system.directoryName,
            producerDigest: DerivedDataTestIdentities.producer.digest
        )
    }

    @Test("libobjc's and Foundation's corpora read back entry for entry")
    func realCorporaRoundTrip() async throws {
        let engine = try await Self.makeEngine("round-trip", loading: [Self.libobjcPath, Self.foundationPath])
        for imagePath in [Self.libobjcPath, Self.foundationPath] {
            _ = try await engine.buildInterfaceCorpus(for: imagePath, transformer: .default)
            let corpus = try #require(await engine.interfaceCorpusStore.corpus(for: imagePath))
            let file = RuntimeDerivedDataContainer.encoded(try RuntimeInterfaceCorpusSnapshot.containerBuilder(for: corpus), header: Self.header(for: imagePath))
            let restored = try RuntimeInterfaceCorpusSnapshot.corpus(
                from: try RuntimeDerivedDataContainer(decoding: file, expecting: Self.header(for: imagePath)),
                transformer: .default
            )
            #expect(restored.entries.count == corpus.entries.count)
            #expect(restored.summary == corpus.summary)
            for (restoredEntry, entry) in zip(restored.entries, corpus.entries) {
                #expect(restoredEntry.object == entry.object)
                #expect(restoredEntry.object.children == entry.object.children)
                #expect(restoredEntry.interface == entry.interface)
                #expect(restoredEntry.visibilityRegions == entry.visibilityRegions)
                #expect(restoredEntry.members == entry.members)
                #expect(restoredEntry.memberDeclarationLineRanges == entry.memberDeclarationLineRanges)
                #expect(restoredEntry.nestedDefinitionRanges == entry.nestedDefinitionRanges)
            }
        }
    }

    @Test("An engine that restores another engine's corpus answers searches as that engine does, unindexed")
    func restoredEngineSearchesTheSame() async throws {
        let directory = try DerivedDataTestDirectory()
        let derivedData = DerivedDataTestIdentities.store(in: directory)
        let printing = try await Self.makeEngine("printing", loading: [Self.libobjcPath])
        await printing.useDerivedDataStore(derivedData)
        let summary = try await printing.buildInterfaceCorpus(for: Self.libobjcPath, transformer: .default)

        let restoring = try await Self.makeEngine("restoring", loading: [])
        await restoring.useDerivedDataStore(derivedData)
        #expect(try await !restoring.isImageIndexed(path: Self.libobjcPath))
        let result = try await restoring.restoreInterfaceCorpora(for: [Self.libobjcPath], transformer: .default)
        #expect(result.restoredImagesByImagePath[Self.libobjcPath]?.summary == summary)
        let coverage = try await restoring.interfaceCorpusCoverage()
        #expect(coverage.statesByImagePath[Self.libobjcPath] == .built(summary))
        #expect(coverage.restoredImagesByImagePath[Self.libobjcPath] != nil)

        for query in [
            RuntimeInterfaceSearchQuery(text: "objc_", matchMode: .containing),
            RuntimeInterfaceSearchQuery(text: "retain", matchMode: .matchingWord, isCaseSensitive: true),
            RuntimeInterfaceSearchQuery(text: #"\binit\w*"#, matchMode: .regularExpression),
        ] {
            #expect(try await Self.matches(of: query, on: restoring) == Self.matches(of: query, on: printing))
        }
        let memberQuery = RuntimeMemberSearchQuery(text: "init", matchMode: .startingWith)
        #expect(try await Self.memberMatches(of: memberQuery, on: restoring) == Self.memberMatches(of: memberQuery, on: printing))
    }

    @Test("An engine without derived data restores nothing")
    func noDerivedData() async throws {
        let engine = try await Self.makeEngine("no-derived-data", loading: [])
        #expect(try await engine.restoreInterfaceCorpora(for: [Self.libobjcPath], transformer: .default) == .empty)
        #expect(try await engine.interfaceCorpusCoverage().statesByImagePath.isEmpty)
    }

    private static func matches(of query: RuntimeInterfaceSearchQuery, on engine: RuntimeEngine) async throws -> [RuntimeInterfaceSearchMatch] {
        let collected = SearchMatches<RuntimeInterfaceSearchMatch>()
        _ = try await engine.searchInterfaces(query) { await collected.append($0) }
        return await collected.matches
    }

    private static func memberMatches(of query: RuntimeMemberSearchQuery, on engine: RuntimeEngine) async throws -> [RuntimeMemberMatch] {
        let collected = SearchMatches<RuntimeMemberMatch>()
        _ = try await engine.searchMembers(query) { await collected.append($0) }
        return await collected.matches
    }

    private actor SearchMatches<Match: Sendable> {
        private(set) var matches: [Match] = []

        func append(_ batch: [Match]) {
            matches += batch
        }
    }

    // MARK: - Timing

    /// The measurement landing step 2 asks for: how long Foundation's,
    /// SwiftUI's and AppKit's corpora take to print, to write and to read
    /// back — the read also taken apart into its phases — and how large they
    /// are on disk. Opt in, in a release build:
    ///
    /// ```
    /// RUNTIMEVIEWER_DERIVED_DATA_TIMING=1 swift test -c release -Xswiftc -enable-testing --filter RuntimeInterfaceCorpusDerivedDataEngineTests
    /// ```
    @Test(
        "Printing, writing and reading Foundation's, SwiftUI's and AppKit's corpora",
        .enabled(if: ProcessInfo.processInfo.environment["RUNTIMEVIEWER_DERIVED_DATA_TIMING"] == "1"),
        .timeLimit(.minutes(20))
    )
    func timing() async throws {
        let directory = try DerivedDataTestDirectory()
        let derivedData = DerivedDataTestIdentities.store(in: directory)
        let engine = try await Self.makeEngine("timing", loading: [Self.libobjcPath])
        await engine.useDerivedDataStore(derivedData)
        var report: [String] = []
        for imagePath in [Self.foundationPath, Self.swiftUIPath, Self.appKitPath] {
            let indexingStart = Date()
            try await engine.loadImage(at: imagePath)
            let indexing = Date().timeIntervalSince(indexingStart)

            let printingStart = Date()
            let summary = try await engine.buildInterfaceCorpus(for: imagePath, transformer: .default)
            let printingAndWriting = Date().timeIntervalSince(printingStart)
            let corpus = try #require(await engine.interfaceCorpusStore.corpus(for: imagePath))

            let encodingStart = Date()
            let builder = try RuntimeInterfaceCorpusSnapshot.containerBuilder(for: corpus)
            let encoding = Date().timeIntervalSince(encodingStart)
            let containerURL = try #require(derivedData.containerURL(.interfaceCorpus, variant: RuntimeInterfaceCorpusSnapshot.variant(for: .default), forImageAt: imagePath))
            let fileByteCount = (try? FileManager.default.attributesOfItem(atPath: containerURL.path)[.size] as? Int) ?? 0

            let reading = try await Self.engineReadTime(imagePath: imagePath, derivedData: derivedData)
            let line = "\(URL(fileURLWithPath: imagePath).lastPathComponent): \(summary.objectCount) objects, \(summary.byteCount / 1024) KiB resident, indexing \(Self.seconds(indexing)), printing and writing \(Self.seconds(printingAndWriting)), encoding \(Self.seconds(encoding)), file \(fileByteCount / 1024) KiB (\(builder.decodedByteCount / 1024) KiB decoded), reading \(reading.map(Self.seconds) ?? "nothing")"
            report.append(line)
            report.append("  read phases: " + (try Self.readPhases(of: containerURL, imagePath: imagePath)))
        }
        let reportText = report.joined(separator: "\n")
        print("Derived data timing:\n" + reportText)
        try reportText.write(to: directory.url.deletingLastPathComponent().appendingPathComponent("RuntimeViewerDerivedDataTiming.txt"), atomically: true, encoding: .utf8)
    }

    /// What reading the image's stored corpus takes for a fresh engine, as
    /// the read itself reports it.
    private static func engineReadTime(imagePath: String, derivedData: RuntimeDerivedDataStore) async throws -> TimeInterval? {
        let engine = try await makeEngine("timing-read", loading: [])
        await engine.useDerivedDataStore(derivedData)
        let result = try await engine.restoreInterfaceCorpora(for: [imagePath], transformer: .default)
        return result.restoredImagesByImagePath[imagePath]?.duration
    }

    /// The read taken apart: the container's checks and decompression, the
    /// objects' property list, the whole decode, and the walk through what it
    /// built, each timed on its own.
    private static func readPhases(of containerURL: URL, imagePath: String) throws -> String {
        let header = Self.header(for: imagePath)
        let fileReadStart = Date()
        let data = try Data(contentsOf: containerURL)
        let fileRead = Date().timeIntervalSince(fileReadStart)
        let containerStart = Date()
        let container = try RuntimeDerivedDataContainer(decoding: data, expecting: header)
        let containerDecoding = Date().timeIntervalSince(containerStart)
        let decoder = PropertyListDecoder()
        let objectsStart = Date()
        _ = try decoder.decode([RuntimeObject].self, from: container.section(RuntimeInterfaceCorpusSnapshot.Section.objects.identifier))
        let objects = Date().timeIntervalSince(objectsStart)
        let corpusStart = Date()
        let corpus = try RuntimeInterfaceCorpusSnapshot.corpus(from: container, transformer: .default)
        let corpusDecoding = Date().timeIntervalSince(corpusStart)
        let walkStart = Date()
        RuntimeInterfaceCorpusSnapshot.walkThrough(corpus.entries)
        let walk = Date().timeIntervalSince(walkStart)
        return "file \(seconds(fileRead)), container \(seconds(containerDecoding)), objects \(seconds(objects)), whole decode with its walk \(seconds(corpusDecoding)), the walk alone \(seconds(walk))"
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.3f s", interval)
    }
}
