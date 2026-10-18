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

    /// A session whose images never change, so that nothing starts a new
    /// generation under a test; as many scans at once as the machine has cores.
    private static func makeSession() -> CrossReferenceSession {
        CrossReferenceSession(maximumConcurrentScans: ProcessInfo.processInfo.activeProcessorCount, imagesOutsideSharedCache: { [] })
    }

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

        // Room for Foundation alone: libobjc, used less recently, goes.
        session.setPreparedByteLimit(foundation.byteCount)
        #expect(session.preparedImageIndices.count == 1)
        #expect(session.preparedByteCount == foundation.byteCount)

        session.setPreparedByteLimit(0)
        #expect(session.preparedImageIndices.isEmpty)
        #expect(session.preparedByteCount == 0)
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
