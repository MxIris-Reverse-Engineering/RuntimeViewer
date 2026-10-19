#if arch(arm64)
import Testing
import Foundation
import RuntimeViewerCore
import CrossReferenceAnalysis
@testable import RuntimeViewerCrossReferences

/// Prepared cross references: an indexed image's references read once and
/// kept, so that later queries answer without scanning — what the app's
/// Keep Cross References Ready asks of the engine's process.
@Suite("Prepared cross references")
struct CrossReferencePreparationTests {
    private static let appKitPath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
    private static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"
    private static let libobjcPath = "/usr/lib/libobjc.A.dylib"

    /// A session whose images never change, so that nothing the process loads
    /// or unloads meanwhile decides a test's analyzer; as many scans at once
    /// as the machine has cores. It reads the prefilters' tables only when a
    /// test asks: seconds of a core each.
    private static func makeSession(preparesPrefilters: Bool = false) -> CrossReferenceSession {
        CrossReferenceSession(maximumConcurrentScans: ProcessInfo.processInfo.activeProcessorCount, preparesPrefilters: preparesPrefilters, imagesOutsideSharedCache: { [] })
    }

    /// A session that sees the images loaded outside the shared cache that
    /// `processImages` lists, which a test changes as the process would.
    private static func makeSession(seeing processImages: ProcessImageList) -> CrossReferenceSession {
        CrossReferenceSession(maximumConcurrentScans: ProcessInfo.processInfo.activeProcessorCount, preparesPrefilters: false, imagesOutsideSharedCache: { processImages.headers })
    }

    private static let roomyPreparationOptions = RuntimeCrossReferencePreparationOptions(residentByteLimit: CrossReferenceSession.defaultPreparedByteLimit)

    /// An image indexed after the analyzer was made, loaded from outside the
    /// shared cache as an app's own framework is: one the analyzer does not
    /// number.
    private static let imageLoadedLaterPath = "/Applications/Loaded Later.app/Contents/Frameworks/LoadedLater.framework/Versions/A/LoadedLater"

    private static func makeQuery(session: CrossReferenceSession, indexedImagePaths: [String]) -> CrossReferenceQuery {
        CrossReferenceQuery(engine: RuntimeEngine(source: .local, engineID: "test-cross-reference-preparation"), session: session) { indexedImagePaths }
    }

    private static let preparedOptions = RuntimeCrossReferenceQueryOptions(preparedIndexByteLimit: CrossReferenceSession.defaultPreparedByteLimit)

    @Test("A query reading prepared indexes answers what a query scanning answers")
    func preparedQueriesAnswerLikeScans() async throws {
        let scanning = Self.makeQuery(session: Self.makeSession(), indexedImagePaths: [Self.appKitPath, Self.libobjcPath])
        let prepared = Self.makeQuery(session: Self.makeSession(), indexedImagePaths: [Self.appKitPath, Self.libobjcPath])

        let scannedCallers = try await scanning.callers(of: .selector("orderWindow:relativeTo:"), in: .indexedImages, options: RuntimeCrossReferenceQueryOptions()) { _ in }
        let preparedCallers = try await prepared.callers(of: .selector("orderWindow:relativeTo:"), in: .indexedImages, options: Self.preparedOptions) { _ in }
        #expect(!preparedCallers.references.isEmpty)
        #expect(preparedCallers == scannedCallers)

        let window = RuntimeObject(name: "NSWindow", displayName: "NSWindow", kind: .objc(.type(.class)), imagePath: Self.appKitPath, children: [])
        let scannedReferences = try await scanning.typeReferences(to: window, in: .indexedImages, options: RuntimeCrossReferenceQueryOptions()) { _ in }
        let preparedReferences = try await prepared.typeReferences(to: window, in: .indexedImages, options: Self.preparedOptions) { _ in }
        #expect(!preparedReferences.references.isEmpty)
        #expect(preparedReferences == scannedReferences)
    }

    @Test("Once an image is prepared, queries about anything in it read the index and scan nothing")
    func preparedImagesAreNotScannedAgain() async throws {
        let session = Self.makeSession()
        let query = Self.makeQuery(session: session, indexedImagePaths: [Self.appKitPath])
        let preparation = try await query.prepare(imageAt: Self.appKitPath, options: RuntimeCrossReferencePreparationOptions(residentByteLimit: CrossReferenceSession.defaultPreparedByteLimit)) { _ in }
        #expect(preparation.referenceCount > 0)
        #expect(preparation.byteCount > 0)
        #expect(session.startedPreparationCount == 1)

        _ = try await query.callers(of: .selector("orderWindow:relativeTo:"), in: .indexedImages, options: Self.preparedOptions) { _ in }
        _ = try await query.callers(of: .selector("makeKeyAndOrderFront:"), in: .image(path: Self.appKitPath), options: Self.preparedOptions) { _ in }
        let window = RuntimeObject(name: "NSWindow", displayName: "NSWindow", kind: .objc(.type(.class)), imagePath: Self.appKitPath, children: [])
        _ = try await query.typeReferences(to: window, in: .indexedImages, options: Self.preparedOptions) { _ in }
        #expect(session.startedPreparationCount == 1)
        #expect(session.startedScanCount == 0)
    }

    @Test("A query for an image not prepared yet prepares it, once, for every requester")
    func requestersShareOnePreparation() async throws {
        let session = Self.makeSession()
        let query = Self.makeQuery(session: session, indexedImagePaths: [Self.appKitPath])
        let options = RuntimeCrossReferencePreparationOptions(residentByteLimit: CrossReferenceSession.defaultPreparedByteLimit)
        async let background = query.prepare(imageAt: Self.appKitPath, options: options) { _ in }
        async let callers = query.callers(of: .selector("orderWindow:relativeTo:"), in: .image(path: Self.appKitPath), options: Self.preparedOptions) { _ in }
        let (preparation, result) = try await (background, callers)
        #expect(preparation.referenceCount > 0)
        #expect(!result.references.isEmpty)
        #expect(session.startedPreparationCount == 1)
        #expect(session.preparedImageIndices.count == 1)
    }

    @Test("Prepared indexes stay within the byte limit, the least recently used dropped first; zero drops them all")
    func preparedIndexesStayWithinTheLimit() async throws {
        let session = Self.makeSession()
        let query = Self.makeQuery(session: session, indexedImagePaths: [Self.libobjcPath, Self.foundationPath])
        let roomy = RuntimeCrossReferencePreparationOptions(residentByteLimit: CrossReferenceSession.defaultPreparedByteLimit)
        let libobjc = try await query.prepare(imageAt: Self.libobjcPath, options: roomy) { _ in }
        let foundation = try await query.prepare(imageAt: Self.foundationPath, options: roomy) { _ in }
        #expect(session.preparedImageIndices.count == 2)
        #expect(session.preparedByteCount == libobjc.byteCount + foundation.byteCount)

        // Room for Foundation alone: libobjc, used less recently, goes, and
        // the analyzer lets go of the names read for it.
        let (analyzer, _) = try session.currentAnalyzer()
        let libobjcIndex = try #require(analyzer.imageIndex(forPath: Self.libobjcPath))
        let foundationIndex = try #require(analyzer.imageIndex(forPath: Self.foundationPath))
        #expect(analyzer.approximateByteCount(ofImageDataAt: libobjcIndex) > 0)
        session.setPreparedByteLimit(foundation.byteCount)
        #expect(session.preparedImageIndices == [foundationIndex])
        #expect(session.preparedByteCount == foundation.byteCount)
        #expect(analyzer.approximateByteCount(ofImageDataAt: libobjcIndex) == 0)
        #expect(analyzer.approximateByteCount(ofImageDataAt: foundationIndex) > 0)

        session.setPreparedByteLimit(0)
        #expect(session.preparedImageIndices.isEmpty)
        #expect(session.preparedByteCount == 0)
        #expect(analyzer.approximateByteCount(ofImageDataAt: foundationIndex) == 0)
    }

    @Test("Preparing an image reads the names its answers are shown with, says so, and counts them against the limit")
    func preparationReadsNamesAndCountsThem() async throws {
        let recorder = PreparationProgressRecorder()
        let session = Self.makeSession()
        let query = Self.makeQuery(session: session, indexedImagePaths: [Self.libobjcPath])
        let roomy = RuntimeCrossReferencePreparationOptions(residentByteLimit: CrossReferenceSession.defaultPreparedByteLimit)
        let preparation = try await query.prepare(imageAt: Self.libobjcPath, options: roomy) { recorder.record($0) }
        let (analyzer, _) = try session.currentAnalyzer()
        let libobjc = try #require(analyzer.imageIndex(forPath: Self.libobjcPath))
        let namingByteCount = analyzer.approximateByteCount(ofImageDataAt: libobjc)
        #expect(namingByteCount > 0)
        #expect(preparation.byteCount > namingByteCount)
        // The last report: every function scanned, the names being read.
        let deadline = Date().addingTimeInterval(10)
        while !recorder.reports.contains(where: \.isReadingNames), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let firstReadingNamesReport = recorder.reports.first(where: \.isReadingNames)
        let readingNames = try #require(firstReadingNamesReport)
        #expect(readingNames.functionCount > 0)
        #expect(readingNames.scannedFunctionCount == readingNames.functionCount)
        #expect(readingNames.isAhead(of: RuntimeCrossReferencePreparationProgress(scannedFunctionCount: readingNames.functionCount, functionCount: readingNames.functionCount)))

        // A limit with room for the references but not their names keeps
        // nothing.
        let indexOnly = preparation.byteCount - namingByteCount
        let tightSession = Self.makeSession()
        let tightQuery = Self.makeQuery(session: tightSession, indexedImagePaths: [Self.libobjcPath])
        _ = try await tightQuery.prepare(imageAt: Self.libobjcPath, options: RuntimeCrossReferencePreparationOptions(residentByteLimit: indexOnly)) { _ in }
        #expect(tightSession.preparedImageIndices.isEmpty)
    }

    @Test("Past the function table limit, the analyzer lets go of other images' names but keeps the prepared images'")
    func preparedNamesOutliveTheFunctionTableLimit() async throws {
        let session = Self.makeSession()
        let query = Self.makeQuery(session: session, indexedImagePaths: [Self.libobjcPath])
        _ = try await query.prepare(imageAt: Self.libobjcPath, options: RuntimeCrossReferencePreparationOptions(residentByteLimit: CrossReferenceSession.defaultPreparedByteLimit)) { _ in }
        let (analyzer, generation) = try session.currentAnalyzer()
        let libobjc = try #require(analyzer.imageIndex(forPath: Self.libobjcPath))
        let foundation = try #require(analyzer.imageIndex(forPath: Self.foundationPath))
        let preparedByteCount = analyzer.approximateByteCount(ofImageDataAt: libobjc)
        // A callee named in Foundation kept its table.
        analyzer.keepFunctionTable(ofImageAt: foundation)
        session.noteFunctionTables(ofImagesAt: [foundation], generation: generation)
        #expect(analyzer.approximateByteCount(ofImageDataAt: foundation) > 0)

        let otherImages = analyzer.images.indices.filter { $0 != libobjc && $0 != foundation }.prefix(CrossReferenceSession.functionTableImageLimit)
        session.noteFunctionTables(ofImagesAt: otherImages, generation: generation)
        let (analyzerAfter, generationAfter) = try session.currentAnalyzer()
        #expect(analyzerAfter === analyzer)
        #expect(generationAfter == generation)
        #expect(analyzer.approximateByteCount(ofImageDataAt: libobjc) == preparedByteCount)
        #expect(analyzer.approximateByteCount(ofImageDataAt: foundation) == 0)
        #expect(session.preparedImageIndices == [libobjc])
    }

    @Test("The first preparation reads the prefilters' tables behind it")
    func firstPreparationReadsThePrefilters() async throws {
        let session = Self.makeSession(preparesPrefilters: true)
        let query = Self.makeQuery(session: session, indexedImagePaths: [Self.libobjcPath])
        let options = RuntimeCrossReferencePreparationOptions(residentByteLimit: CrossReferenceSession.defaultPreparedByteLimit)
        _ = try await query.prepare(imageAt: Self.libobjcPath, options: options) { _ in }
        let (_, generation) = try session.currentAnalyzer()
        let deadline = Date().addingTimeInterval(120)
        while session.preparedPrefilterGeneration != generation, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(session.preparedPrefilterGeneration == generation)
    }

    @Test("An image that is not indexed is not prepared")
    func preparationNeedsAnIndexedImage() async throws {
        let session = Self.makeSession()
        let query = Self.makeQuery(session: session, indexedImagePaths: [Self.libobjcPath])
        await #expect(throws: RuntimeCrossReferenceError.imageNotIndexed(path: Self.foundationPath)) {
            try await query.prepare(imageAt: Self.foundationPath, options: RuntimeCrossReferencePreparationOptions(residentByteLimit: CrossReferenceSession.defaultPreparedByteLimit)) { _ in }
        }
        #expect(session.startedPreparationCount == 0)
    }

    @Test("Cancelling the only requester stops the preparation, and keeps nothing")
    func cancellingTheOnlyRequesterStopsThePreparation() async throws {
        let session = Self.makeSession()
        let query = Self.makeQuery(session: session, indexedImagePaths: [Self.appKitPath])
        let (firstReport, firstReportContinuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await query.prepare(imageAt: Self.appKitPath, options: RuntimeCrossReferencePreparationOptions(residentByteLimit: CrossReferenceSession.defaultPreparedByteLimit)) { _ in
                firstReportContinuation.yield()
            }
        }
        for await _ in firstReport { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // The scan gives up at its next progress report.
        let deadline = Date().addingTimeInterval(60)
        while session.hasPreparationsUnderWay, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(!session.hasPreparationsUnderWay)
        #expect(session.preparedImageIndices.isEmpty)
    }

    @Test("An engine prepares an image it has indexed, refuses one it has not, and its queries read what it prepared")
    func enginesPrepareTheirIndexedImages() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "test-cross-reference-preparation-engine")
        try await engine.connect()
        try await engine.loadImage(at: Self.libobjcPath)
        let options = RuntimeCrossReferencePreparationOptions(residentByteLimit: CrossReferenceSession.defaultPreparedByteLimit)
        let recorder = PreparationProgressRecorder()
        let preparation = try await engine.prepareCrossReferences(forImageAt: Self.libobjcPath, options: options) { recorder.record($0) }
        #expect(preparation.referenceCount > 0)
        // Progress travels on its own as the scan goes: the last report may
        // land just after the result.
        let deadline = Date().addingTimeInterval(10)
        while !recorder.reports.contains(where: { $0.functionCount > 0 && $0.scannedFunctionCount == $0.functionCount }), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(recorder.reports.contains { $0.functionCount > 0 && $0.scannedFunctionCount == $0.functionCount })

        await #expect(throws: RuntimeCrossReferenceError.imageNotIndexed(path: Self.foundationPath)) {
            try await engine.prepareCrossReferences(forImageAt: Self.foundationPath, options: options)
        }

        let scanned = try await engine.callers(of: .selector("description"), in: .image(path: Self.libobjcPath))
        let prepared = try await engine.callers(of: .selector("description"), in: .image(path: Self.libobjcPath), options: Self.preparedOptions)
        #expect(!prepared.references.isEmpty)
        #expect(prepared == scanned)
    }

    // MARK: - Images loaded and unloaded

    @Test("An image loaded outside the shared cache after the preparation keeps the analyzer, and with it the prepared images and their names")
    func imagesLoadedLaterKeepThePreparedImages() async throws {
        let processImages = ProcessImageList([])
        let session = Self.makeSession(seeing: processImages)
        let query = Self.makeQuery(session: session, indexedImagePaths: [Self.foundationPath])
        _ = try await query.prepare(imageAt: Self.foundationPath, options: Self.roomyPreparationOptions) { _ in }
        let (analyzer, generation) = try session.currentAnalyzer()
        let foundation = try #require(analyzer.imageIndex(forPath: Self.foundationPath))
        let namingByteCount = analyzer.approximateByteCount(ofImageDataAt: foundation)
        #expect(namingByteCount > 0)

        // What generating an interface did in the engine's process, after the
        // indexed images were prepared: a class's `+initialize` made a method
        // from a block, and the Objective-C runtime loaded
        // `libobjc-trampolines.dylib`, which is not in the cache.
        processImages.load(0x7_0000_0000)
        let url = RuntimeObject(name: "10Foundation3URLV", displayName: "URL", kind: .swift(.type(.struct)), imagePath: Self.foundationPath, children: [])
        let result = try await query.typeReferences(to: url, in: .image(path: Self.foundationPath), options: Self.preparedOptions) { _ in }
        #expect(!result.references.isEmpty)
        // Answered from the index prepared ahead, not one prepared again.
        #expect(session.startedPreparationCount == 1)
        #expect(session.preparedImageIndices == [foundation])
        let (analyzerAfter, generationAfter) = try session.currentAnalyzer()
        #expect(analyzerAfter === analyzer)
        #expect(generationAfter == generation)
        #expect(analyzer.approximateByteCount(ofImageDataAt: foundation) >= namingByteCount)
    }

    @Test("An image loaded later that a query asks about renews the analyzer, which keeps what was prepared and reads its names again")
    func imagesAskedAboutRenewTheAnalyzer() async throws {
        let processImages = ProcessImageList([])
        let session = Self.makeSession(seeing: processImages)
        let query = Self.makeQuery(session: session, indexedImagePaths: [Self.libobjcPath, Self.imageLoadedLaterPath])
        _ = try await query.prepare(imageAt: Self.libobjcPath, options: Self.roomyPreparationOptions) { _ in }
        let callers = try await query.callers(of: .selector("description"), in: .image(path: Self.libobjcPath), options: Self.preparedOptions) { _ in }
        #expect(!callers.references.isEmpty)
        let (analyzer, generation) = try session.currentAnalyzer()
        let libobjc = try #require(analyzer.imageIndex(forPath: Self.libobjcPath))

        // The indexed image the analyzer lacks is loaded now. A preparation
        // request — the app makes one for every image the engine reports
        // indexed — renews the analyzer; libobjc, asked for again, is found
        // prepared, and nothing is named.
        processImages.load(0x7_0000_0000)
        _ = try await query.prepare(imageAt: Self.libobjcPath, options: Self.roomyPreparationOptions) { _ in }
        let (renewed, renewedGeneration) = try session.currentAnalyzer()
        #expect(renewed !== analyzer)
        #expect(renewedGeneration == generation + 1)
        #expect(session.startedPreparationCount == 1)
        #expect(session.preparedImageIndices == [libobjc])

        // The renewed analyzer reads the prepared image's names on the
        // session's queue, before any query names what the index answers.
        let deadline = Date().addingTimeInterval(60)
        while renewed.approximateByteCount(ofImageDataAt: libobjc) == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(renewed.approximateByteCount(ofImageDataAt: libobjc) > 0)

        // Nothing loaded since: the next query keeps the renewed analyzer and
        // answers as before.
        let callersAfter = try await query.callers(of: .selector("description"), in: .image(path: Self.libobjcPath), options: Self.preparedOptions) { _ in }
        #expect(callersAfter == callers)
        #expect(try session.currentAnalyzer().generation == renewedGeneration)
        #expect(session.startedPreparationCount == 1)
    }

    @Test("An image the analyzer numbers being unloaded starts over: a new analyzer, and nothing prepared with the old one")
    func imagesUnloadedStartOver() async throws {
        let processImages = ProcessImageList([0x7_0000_0000, 0x7_0001_0000])
        let session = Self.makeSession(seeing: processImages)
        let query = Self.makeQuery(session: session, indexedImagePaths: [Self.libobjcPath])
        _ = try await query.prepare(imageAt: Self.libobjcPath, options: Self.roomyPreparationOptions) { _ in }
        let (analyzer, generation) = try session.currentAnalyzer()

        // Its memory is gone, and the images after it moved up.
        processImages.unload(0x7_0000_0000)
        let callers = try await query.callers(of: .selector("description"), in: .image(path: Self.libobjcPath), options: Self.preparedOptions) { _ in }
        #expect(!callers.references.isEmpty)
        let (analyzerAfter, generationAfter) = try session.currentAnalyzer()
        #expect(analyzerAfter !== analyzer)
        #expect(generationAfter == generation + 1)
        // The query prepared the image again, with the new analyzer.
        #expect(session.startedPreparationCount == 2)
    }

    @Test("A preparation under way when the analyzer is renewed is kept, and the renewed analyzer reads its names")
    func preparationsOutliveARenewal() async throws {
        let processImages = ProcessImageList([])
        let session = Self.makeSession(seeing: processImages)
        let query = Self.makeQuery(session: session, indexedImagePaths: [Self.appKitPath, Self.libobjcPath, Self.imageLoadedLaterPath])
        let (firstReport, firstReportContinuation) = AsyncStream<Void>.makeStream()
        let preparation = Task {
            try await query.prepare(imageAt: Self.appKitPath, options: Self.roomyPreparationOptions) { _ in
                firstReportContinuation.yield()
            }
        }
        for await _ in firstReport { break }
        let (_, generation) = try session.currentAnalyzer()

        // While AppKit is scanned, a query renews the analyzer for the indexed
        // image loaded since.
        processImages.load(0x7_0000_0000)
        _ = try await query.callers(of: .selector("description"), in: .image(path: Self.libobjcPath), options: RuntimeCrossReferenceQueryOptions()) { _ in }
        let (renewed, renewedGeneration) = try session.currentAnalyzer()
        #expect(renewedGeneration == generation + 1)

        _ = try await preparation.value
        let appKit = try #require(renewed.imageIndex(forPath: Self.appKitPath))
        #expect(session.preparedImageIndices == [appKit])
        #expect(session.startedPreparationCount == 1)
        let deadline = Date().addingTimeInterval(60)
        while renewed.approximateByteCount(ofImageDataAt: appKit) == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(renewed.approximateByteCount(ofImageDataAt: appKit) > 0)
    }

    @Test("A preparation request survives a round trip, and so does every outcome")
    func preparationWireFormat() throws {
        let command = RuntimeCrossReferences.PrepareCommand(
            imagePath: Self.appKitPath,
            options: RuntimeCrossReferencePreparationOptions(residentByteLimit: 64 << 20, maximumConcurrentScans: 3, isPrioritized: true)
        )
        let decoded = try JSONDecoder().decode(RuntimeCrossReferences.PrepareCommand.self, from: JSONEncoder().encode(command))
        #expect(decoded.imagePath == command.imagePath)
        #expect(decoded.options == command.options)
        #expect(RuntimeCrossReferences.PrepareCommand.cancelsAcrossConnections)

        for outcome in [RuntimeCrossReferencePreparationOutcome.prepared(RuntimeCrossReferencePreparation(referenceCount: 12, byteCount: 3400)), .cancelled, .imageNotIndexed] {
            let decodedOutcome = try JSONDecoder().decode(RuntimeCrossReferencePreparationOutcome.self, from: JSONEncoder().encode(outcome))
            #expect(String(describing: decodedOutcome) == String(describing: outcome))
        }
        let options = RuntimeCrossReferenceQueryOptions(resultLimit: 10, maximumConcurrentScans: 2, preparedIndexByteLimit: 1 << 20)
        #expect(try JSONDecoder().decode(RuntimeCrossReferenceQueryOptions.self, from: JSONEncoder().encode(options)) == options)
    }

    /// The header addresses of the images loaded outside the shared cache, in
    /// dyld's order, as a session asks for them: what a test loads and
    /// unloads. The analyzer is made from the process's own images; only the
    /// session's decisions follow this list.
    private final class ProcessImageList: @unchecked Sendable {
        private let lock = NSLock()
        private var loadedHeaders: [UInt]

        init(_ headers: [UInt]) {
            loadedHeaders = headers
        }

        var headers: [UInt] {
            lock.lock()
            defer { lock.unlock() }
            return loadedHeaders
        }

        /// dyld adds an image it loads after the others.
        func load(_ header: UInt) {
            lock.lock()
            defer { lock.unlock() }
            loadedHeaders.append(header)
        }

        func unload(_ header: UInt) {
            lock.lock()
            defer { lock.unlock() }
            loadedHeaders.removeAll { $0 == header }
        }
    }

    /// Collects a preparation's progress reports.
    private final class PreparationProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [RuntimeCrossReferencePreparationProgress] = []

        var reports: [RuntimeCrossReferencePreparationProgress] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func record(_ progress: RuntimeCrossReferencePreparationProgress) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(progress)
        }
    }
}
#endif
