import Foundation
import FoundationToolbox
import MachO
import RuntimeViewerCore
import CrossReferenceAnalysis

/// What one process keeps between cross-reference queries: the analyzer, and
/// what earlier scans found image by image.
///
/// Per process, not per engine: the analysis reads this process's own
/// images, so every engine the process serves sees the same thing, and two
/// documents on one engine — or on two — share the scans.
///
/// Nothing is written to disk. Scanning the whole shared cache takes one to
/// four seconds, so a scan is redone rather than stored (proposal decision
/// log, 2026-10-16); what is kept here only spares repeating one within a
/// session — a retry after a time limit, or a call hierarchy node expanded
/// twice.
final class CrossReferenceSession: Sendable {
    /// The process's session. Not behind `@Dependency`, as project singletons
    /// otherwise are: `RuntimeViewerCore` does not depend on swift-dependencies,
    /// nothing outside this file reaches it, and tests hand a query a session
    /// of their own (`CrossReferenceQuery.init(engine:session:)`).
    fileprivate static let shared = CrossReferenceSession()

    /// Bytes of scan results kept between queries. A scan larger than this —
    /// the callers of `init` — is not kept, and every query for it scans
    /// again; once one is found too large, the session stops recording it
    /// until the process's images change, so that it does not push out the
    /// other scans again on its way past the budget each time it is asked
    /// for.
    static let defaultScanByteBudget = 64 << 20

    /// Images whose function tables the analyzer may hold, besides the
    /// prepared ones, before the session releases what it keeps for them.
    /// Naming a callee keeps its image's table; a table runs from kilobytes to
    /// a few megabytes, and a long session names functions in hundreds of
    /// images.
    static let functionTableImageLimit = 64

    /// How many images the process scans at once until a query brings another
    /// count: as many as background indexing builds at once by default.
    static let defaultMaximumConcurrentScans = 4

    private let scanByteBudget: Int
    /// Where every image scan runs, whichever query asked for it: at most
    /// ``maximumConcurrentScans`` at a time, at utility priority, and on
    /// threads of its own. A scan decodes a whole image without suspending;
    /// on the Swift concurrency pool it would hold a thread the engine's other
    /// work in this process — the sidebar, the content pane — is waiting for.
    private let scanQueue: OperationQueue
    /// The header address of every image loaded outside the shared cache, in
    /// dyld's order — what decides whether the analyzer still numbers the
    /// process's images as they are (``currentAnalyzer()``). The process's own
    /// list, unless a test loads and unloads images of its own.
    private let imagesOutsideSharedCache: @Sendable () -> [UInt]
    /// Whether the first preparation of a generation reads the prefilters'
    /// tables behind it: seconds of a core in a debug build, which a test
    /// that does not look at them leaves out.
    private let preparesPrefilters: Bool
    private let state = Mutex(State())

    init(
        scanByteBudget: Int = CrossReferenceSession.defaultScanByteBudget,
        maximumConcurrentScans: Int = CrossReferenceSession.defaultMaximumConcurrentScans,
        preparesPrefilters: Bool = true,
        imagesOutsideSharedCache: @escaping @Sendable () -> [UInt] = { CrossReferenceSession.processImagesOutsideSharedCache() }
    ) {
        self.scanByteBudget = scanByteBudget
        self.preparesPrefilters = preparesPrefilters
        self.imagesOutsideSharedCache = imagesOutsideSharedCache
        scanQueue = OperationQueue()
        scanQueue.name = "com.RuntimeViewer.CrossReferences.scan"
        scanQueue.qualityOfService = .utility
        scanQueue.maxConcurrentOperationCount = max(1, maximumConcurrentScans)
    }

    // MARK: - Analyzer

    /// The analyzer for the process's images, and the generation scans are
    /// filed under.
    ///
    /// An analyzer is a snapshot: images loaded outside the shared cache
    /// after it was made are not in it. It stays while images are only
    /// loaded — the shared cache's images come first and never move, and dyld
    /// lists what it loads after the rest, so every image the analyzer
    /// numbers keeps its number — and what was prepared and scanned with it
    /// stays too. The process loads such images without anyone asking: the
    /// Objective-C runtime loads `libobjc-trampolines.dylib` the first time a
    /// method is made from a block, which a class's `+initialize` does when
    /// generating an interface runs a type's metadata accessor — in the
    /// engine's process, minutes after the indexed images were prepared.
    /// Replacing the analyzer for that would drop every prepared image, and
    /// the next query would wait for its image to be prepared again. A query
    /// about an image loaded since renews the analyzer instead
    /// (``analyzerIncludingImagesLoaded(since:)``).
    ///
    /// An image the analyzer numbers being unloaded is another matter: its
    /// memory is gone and the images after it move up, so a new analyzer
    /// starts over, and everything filed under the old one is dropped.
    func currentAnalyzer() throws -> (analyzer: CrossReferenceAnalyzer, generation: Int) {
        let imagesOutsideSharedCache = self.imagesOutsideSharedCache()
        return try state.withLock { state in
            if let analyzer = state.analyzer, imagesOutsideSharedCache.starts(with: state.imagesOutsideSharedCache) {
                return (analyzer, state.generation)
            }
            return try Self.startOver(with: imagesOutsideSharedCache, in: &state)
        }
    }

    /// An analyzer that also numbers the images loaded outside the shared
    /// cache since the analyzer of `generation` was made — the current one
    /// when another query has made it meanwhile — or `nil` when none was
    /// loaded since: for a query asking about an image that analyzer does not
    /// number, such as an app's own framework the engine indexed after
    /// loading it.
    ///
    /// The images the old analyzer numbers keep their numbers, so what was
    /// prepared and scanned with it stays. The names the old analyzer read
    /// for the prepared images go with it: the new one reads them again on
    /// the session's queue, ahead of the preparations waiting, and the
    /// prefilters' tables behind them.
    func analyzerIncludingImagesLoaded(since generation: Int) throws -> (analyzer: CrossReferenceAnalyzer, generation: Int)? {
        let imagesOutsideSharedCache = self.imagesOutsideSharedCache()
        let renewal = try state.withLock { state -> AnalyzerRenewal? in
            guard let analyzer = state.analyzer else { return nil }
            guard state.generation == generation else {
                return .madeMeanwhile(analyzer, generation: state.generation)
            }
            guard imagesOutsideSharedCache.starts(with: state.imagesOutsideSharedCache) else {
                let (startedOver, startedOverGeneration) = try Self.startOver(with: imagesOutsideSharedCache, in: &state)
                return .madeMeanwhile(startedOver, generation: startedOverGeneration)
            }
            guard imagesOutsideSharedCache.count > state.imagesOutsideSharedCache.count else { return nil }
            guard let renewed = CrossReferenceAnalyzer() else {
                throw RuntimeCrossReferenceError.unsupportedArchitecture
            }
            let loadedImageCount = imagesOutsideSharedCache.count - state.imagesOutsideSharedCache.count
            state.analyzer = renewed
            state.imagesOutsideSharedCache = imagesOutsideSharedCache
            // The function tables kept are the old analyzer's.
            state.imagesWithFunctionTables = []
            state.generation += 1
            return .renewed(
                renewed,
                generation: state.generation,
                loadedImageCount: loadedImageCount,
                preparedImageIndices: Array(state.preparedImages.keys),
                readsPrefilters: state.prefilterPreparationGeneration != nil
            )
        }
        switch renewal {
        case nil:
            return nil
        case .madeMeanwhile(let analyzer, let generation):
            return (analyzer, generation)
        case .renewed(let analyzer, let generation, let loadedImageCount, let preparedImageIndices, let readsPrefilters):
            CrossReferenceSessionLog.renewedAnalyzer(generation: generation, loadedImageCount: loadedImageCount, keptPreparedImageCount: preparedImageIndices.count)
            readNames(ofImagesAt: preparedImageIndices, with: analyzer, generation: generation)
            if readsPrefilters {
                preparePrefiltersIfNeeded(with: analyzer, generation: generation)
            }
            return (analyzer, generation)
        }
    }

    private enum AnalyzerRenewal {
        /// Another query made the current analyzer since the one asked about.
        case madeMeanwhile(CrossReferenceAnalyzer, generation: Int)
        case renewed(CrossReferenceAnalyzer, generation: Int, loadedImageCount: Int, preparedImageIndices: [Int], readsPrefilters: Bool)
    }

    /// Makes the first analyzer, or replaces one an image it numbers left,
    /// and drops everything filed under the old numbering: the scans, the
    /// prepared images, and — with the old analyzer — the names read for them.
    private static func startOver(with imagesOutsideSharedCache: [UInt], in state: inout State) throws -> (analyzer: CrossReferenceAnalyzer, generation: Int) {
        guard let analyzer = CrossReferenceAnalyzer() else {
            throw RuntimeCrossReferenceError.unsupportedArchitecture
        }
        let isFirst = state.analyzer == nil
        let droppedPreparedImageCount = state.preparedImages.count
        state.analyzer = analyzer
        state.imagesOutsideSharedCache = imagesOutsideSharedCache
        state.imagesWithFunctionTables = []
        state.generation += 1
        state.numberingGeneration = state.generation
        state.scans = [:]
        state.oversizedScanKeys = []
        state.scanByteCount = 0
        state.preparedImages = [:]
        state.preparedByteCount = 0
        if isFirst {
            CrossReferenceSessionLog.madeAnalyzer(generation: state.generation, imageCountOutsideSharedCache: imagesOutsideSharedCache.count)
        } else {
            CrossReferenceSessionLog.startedOver(generation: state.generation, droppedPreparedImageCount: droppedPreparedImageCount)
        }
        return (analyzer, state.generation)
    }

    /// The numbering the analyzer of `generation` gave the images: the
    /// current one for a generation since it began, under which prepared
    /// images and scans are filed; an older generation's own, under which
    /// nothing is kept any more.
    private static func numbering(ofGeneration generation: Int, in state: State) -> Int {
        generation >= state.numberingGeneration ? state.numberingGeneration : generation
    }

    /// Records that a query had the analyzer name functions in
    /// `imageIndices`, which keeps their function tables. Past
    /// ``functionTableImageLimit`` images besides the prepared ones, the
    /// analyzer releases what it keeps for every image but the prepared ones
    /// and those being prepared: the names read for those are what lets the
    /// first query about them answer at once.
    ///
    /// Replacing the analyzer instead would drop the prepared images' names
    /// with the rest, and the next query about one of them would read them
    /// again.
    func noteFunctionTables(ofImagesAt imageIndices: some Sequence<Int>, generation: Int) {
        state.withLock { state in
            guard state.generation == generation, let analyzer = state.analyzer else { return }
            state.imagesWithFunctionTables.formUnion(imageIndices)
            let preparedImages = Self.preparedOrPreparingImageIndices(in: state)
            guard state.imagesWithFunctionTables.subtracting(preparedImages).count > Self.functionTableImageLimit else { return }
            analyzer.releaseImageData(exceptForImagesAt: preparedImages)
            state.imagesWithFunctionTables.formIntersection(preparedImages)
        }
    }

    /// The images with an index kept, or a preparation queued or under way,
    /// under the current numbering.
    private static func preparedOrPreparingImageIndices(in state: State) -> Set<Int> {
        var imageIndices = Set(state.preparedImages.keys)
        for key in state.preparations.keys where key.numbering == state.numberingGeneration {
            imageIndices.insert(key.imageIndex)
        }
        return imageIndices
    }

    /// Releases what the analyzer keeps for images whose prepared index was
    /// just dropped; what it keeps for the others stays.
    private static func releaseImageData(ofEvictedImagesAt evictedImageIndices: [Int], in state: inout State) {
        guard !evictedImageIndices.isEmpty, let analyzer = state.analyzer else { return }
        state.imagesWithFunctionTables.subtract(evictedImageIndices)
        analyzer.releaseImageData(exceptForImagesAt: state.imagesWithFunctionTables.union(preparedOrPreparingImageIndices(in: state)))
    }

    /// The header address of every image loaded outside the shared cache, in
    /// dyld's order.
    static func processImagesOutsideSharedCache() -> [UInt] {
        var headers: [UInt] = []
        for imageIndex in 0 ..< _dyld_image_count() {
            guard let header = _dyld_get_image_header(imageIndex) else { continue }
            // MH_DYLIB_IN_CACHE: every shared cache image is in every analyzer.
            guard header.pointee.flags & 0x8000_0000 == 0 else { continue }
            headers.append(UInt(bitPattern: header))
        }
        return headers
    }

    // MARK: - Scans

    /// What earlier scans for `key` found, by image — an image scanned with
    /// nothing found maps to an empty array. Scans with an analyzer renewed
    /// since count: they number the images alike.
    func scannedReferences(for key: CrossReferenceScanKey, generation: Int) -> [Int: [CodeReference]] {
        state.withLock { state in
            guard generation >= state.numberingGeneration, var scan = state.scans[key] else { return [:] }
            state.useCounter += 1
            scan.lastUse = state.useCounter
            state.scans[key] = scan
            return scan.referencesByImage
        }
    }

    /// Files what a scan for `key` found in one image.
    func record(_ references: [CodeReference], for key: CrossReferenceScanKey, inImageAt imageIndex: Int, generation: Int) {
        let byteCount = references.count * MemoryLayout<CodeReference>.stride + MemoryLayout<Int>.stride * 4
        state.withLock { state in
            guard generation >= state.numberingGeneration, !state.oversizedScanKeys.contains(key) else { return }
            state.useCounter += 1
            var scan = state.scans[key] ?? Scan()
            guard scan.referencesByImage[imageIndex] == nil else { return }
            guard scan.byteCount + byteCount <= scanByteBudget else {
                // Larger than everything this session may keep: never kept,
                // what was kept of it so far goes too, and nothing more of it
                // is recorded — the images still to come would start it over
                // and leave part of it behind.
                state.scanByteCount -= scan.byteCount
                state.scans[key] = nil
                state.oversizedScanKeys.insert(key)
                return
            }
            scan.referencesByImage[imageIndex] = references
            scan.byteCount += byteCount
            scan.lastUse = state.useCounter
            state.scans[key] = scan
            state.scanByteCount += byteCount
            evictLeastRecentlyUsedScans(from: &state, keeping: key)
        }
    }

    private func evictLeastRecentlyUsedScans(from state: inout State, keeping keptKey: CrossReferenceScanKey) {
        while state.scanByteCount > scanByteBudget {
            guard let oldest = state.scans.filter({ $0.key != keptKey }).min(by: { $0.value.lastUse < $1.value.lastUse }) else { return }
            state.scanByteCount -= oldest.value.byteCount
            state.scans[oldest.key] = nil
        }
    }

    /// The bytes of scan results kept now; for tests.
    var keptScanByteCount: Int {
        state.withLock { $0.scanByteCount }
    }

    /// How many image scans the session's queries started; for tests.
    var startedScanCount: Int {
        state.withLock { $0.startedScanCount }
    }

    /// How many image scans run at once.
    var maximumConcurrentScans: Int {
        scanQueue.maxConcurrentOperationCount
    }

    /// Sets how many image scans run at once. Scans already running finish;
    /// the count decides which of the waiting ones start.
    func setMaximumConcurrentScans(_ count: Int) {
        scanQueue.maxConcurrentOperationCount = max(1, count)
    }

    /// What scanning the image at `imageIndex` for `key` finds — scanned by
    /// `scan` on the session's queue, unless another query is scanning the
    /// same image for the same key now, whose result this one waits for and
    /// shares. Two parts of one window ask about one subject at once — the
    /// Find navigator and the Inspector — and each image is scanned once for
    /// both.
    ///
    /// The scan runs to its end once started, as a scan of one image always
    /// has; what cancelling a query stops is the images it has not started.
    func sharedScan(of key: CrossReferenceScanKey, inImageAt imageIndex: Int, generation: Int, scan: @escaping @Sendable () -> [CodeReference]) async -> [CodeReference] {
        let scanIdentity = InFlightScan(key: key, imageIndex: imageIndex, generation: generation)
        let task = state.withLock { state -> Task<[CodeReference], Never> in
            if let task = state.inFlightScans[scanIdentity] {
                return task
            }
            state.startedScanCount += 1
            let task = Task { [scanQueue] in
                await withCheckedContinuation { continuation in
                    scanQueue.addOperation {
                        continuation.resume(returning: scan())
                    }
                }
            }
            state.inFlightScans[scanIdentity] = task
            return task
        }
        let references = await task.value
        state.withLock { state in
            if state.inFlightScans[scanIdentity] == task {
                state.inFlightScans[scanIdentity] = nil
            }
        }
        return references
    }

    // MARK: - Prepared images

    /// Bytes of prepared images kept until a request brings another limit:
    /// the Find corpus's default, about seven frameworks of AppKit's size.
    static let defaultPreparedByteLimit = 256 << 20

    /// The image prepared: the one kept, the one being prepared, or one
    /// `build` prepares now on the session's queue. Every requester of an
    /// image shares one preparation; a prioritized one — a query waiting —
    /// moves it ahead of the preparations waiting, and the queries' own scans
    /// go ahead of every preparation that is not prioritized.
    ///
    /// A requester that is cancelled stops waiting at once. A preparation
    /// every requester has left is stopped: not started if it has not
    /// started, given up between two progress reports if it has.
    ///
    /// The image is kept within the byte limit, its index and the names the
    /// analyzer read for it counted together, least recently used dropped
    /// first — the analyzer releasing the names of one dropped. One larger
    /// than the limit is returned and not kept.
    ///
    /// An image prepared with an analyzer renewed since is kept all the same,
    /// and the renewed analyzer reads its names.
    func preparedImage(
        ofImageAt imageIndex: Int,
        generation: Int,
        isPrioritized: Bool,
        reportProgress: (@Sendable (RuntimeCrossReferencePreparationProgress) async -> Void)? = nil,
        build: @escaping @Sendable (_ shouldContinue: @escaping (RuntimeCrossReferencePreparationProgress) -> Bool) -> CrossReferencePreparedImage?
    ) async throws -> CrossReferencePreparedImage {
        if let ready = state.withLock({ Self.takeReadyImage(ofImageAt: imageIndex, generation: generation, from: &$0) }) {
            return ready
        }
        let key = state.withLock { PreparationKey(imageIndex: imageIndex, numbering: Self.numbering(ofGeneration: generation, in: $0)) }
        let waiterIdentifier = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediateResult = state.withLock { state -> Result<CrossReferencePreparedImage, any Error>? in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if let ready = Self.takeReadyImage(ofImageAt: imageIndex, generation: generation, from: &state) { return .success(ready) }
                    if var preparation = state.preparations[key] {
                        preparation.waiters[waiterIdentifier] = continuation
                        preparation.progressHandlers[waiterIdentifier] = reportProgress
                        preparation.isAbandoned = false
                        if isPrioritized { preparation.operation.queuePriority = .veryHigh }
                        state.preparations[key] = preparation
                    } else {
                        let operation = makePreparationOperation(for: key, isPrioritized: isPrioritized, build: build)
                        var preparation = Preparation(operation: operation, buildGeneration: generation)
                        preparation.waiters[waiterIdentifier] = continuation
                        preparation.progressHandlers[waiterIdentifier] = reportProgress
                        state.preparations[key] = preparation
                        scanQueue.addOperation(operation)
                    }
                    return nil
                }
                if let immediateResult { continuation.resume(with: immediateResult) }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<CrossReferencePreparedImage, any Error>? in
                guard var preparation = state.preparations[key], let continuation = preparation.waiters.removeValue(forKey: waiterIdentifier) else { return nil }
                preparation.progressHandlers[waiterIdentifier] = nil
                if preparation.waiters.isEmpty { preparation.isAbandoned = true }
                state.preparations[key] = preparation
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func makePreparationOperation(
        for key: PreparationKey,
        isPrioritized: Bool,
        build: @escaping @Sendable (_ shouldContinue: @escaping (RuntimeCrossReferencePreparationProgress) -> Bool) -> CrossReferencePreparedImage?
    ) -> Operation {
        let operation = BlockOperation { [weak self] in
            self?.runPreparation(for: key, build: build)
        }
        operation.queuePriority = isPrioritized ? .veryHigh : .low
        return operation
    }

    private func runPreparation(for key: PreparationKey, build: @escaping @Sendable (_ shouldContinue: @escaping (RuntimeCrossReferencePreparationProgress) -> Bool) -> CrossReferencePreparedImage?) {
        let shouldStart = state.withLock { state -> Bool in
            guard let preparation = state.preparations[key] else { return false }
            if preparation.isAbandoned {
                state.preparations[key] = nil
                return false
            }
            state.startedPreparationCount += 1
            return true
        }
        guard shouldStart else { return }

        let prepared = build { [self] progress in
            let (handlers, isAbandoned) = state.withLock { state in
                (state.preparations[key].map { Array($0.progressHandlers.values) } ?? [], state.preparations[key]?.isAbandoned ?? true)
            }
            if !handlers.isEmpty {
                Task {
                    for handler in handlers {
                        await handler(progress)
                    }
                }
            }
            return !isAbandoned
        }

        enum Completion {
            case answer([CheckedContinuation<CrossReferencePreparedImage, any Error>], CrossReferencePreparedImage, namesToRead: (analyzer: CrossReferenceAnalyzer, generation: Int)?)
            case restart(isPrioritized: Bool)
            case none
        }
        let completion = state.withLock { state -> Completion in
            guard let preparation = state.preparations[key] else { return .none }
            guard let prepared else {
                // Stopped because every requester had left; one may have come
                // back meanwhile.
                guard !preparation.waiters.isEmpty else {
                    state.preparations[key] = nil
                    return .none
                }
                return .restart(isPrioritized: preparation.operation.queuePriority == .veryHigh)
            }
            state.preparations[key] = nil
            var namesToRead: (analyzer: CrossReferenceAnalyzer, generation: Int)?
            if key.numbering == state.numberingGeneration {
                keep(prepared, ofImageAt: key.imageIndex, from: &state)
                // Read with an analyzer renewed since, which holds the names
                // it read: the current one reads them too.
                if preparation.buildGeneration != state.generation, state.preparedImages[key.imageIndex] != nil, let analyzer = state.analyzer {
                    namesToRead = (analyzer, state.generation)
                }
            }
            return .answer(Array(preparation.waiters.values), prepared, namesToRead: namesToRead)
        }
        switch completion {
        case .answer(let continuations, let prepared, let namesToRead):
            if let namesToRead {
                readNames(ofImagesAt: [key.imageIndex], with: namesToRead.analyzer, generation: namesToRead.generation)
            }
            for continuation in continuations {
                continuation.resume(returning: prepared)
            }
        case .restart(let isPrioritized):
            let operation = makePreparationOperation(for: key, isPrioritized: isPrioritized, build: build)
            state.withLock { state in
                state.preparations[key]?.operation = operation
                state.preparations[key]?.isAbandoned = false
            }
            scanQueue.addOperation(operation)
        case .none:
            break
        }
    }

    /// The image kept, marked as just used — for an analyzer that numbers the
    /// images as the one that prepared it did.
    private static func takeReadyImage(ofImageAt imageIndex: Int, generation: Int, from state: inout State) -> CrossReferencePreparedImage? {
        guard generation >= state.numberingGeneration, var kept = state.preparedImages[imageIndex] else { return nil }
        state.useCounter += 1
        kept.lastUse = state.useCounter
        state.preparedImages[imageIndex] = kept
        return kept.prepared
    }

    /// Keeps the image within the byte limit. One larger than the limit is
    /// not kept; the names read for it go the way of any image's a query
    /// named functions in (``noteFunctionTables(ofImagesAt:generation:)``).
    private func keep(_ prepared: CrossReferencePreparedImage, ofImageAt imageIndex: Int, from state: inout State) {
        guard prepared.byteCount <= state.preparedByteLimit else { return }
        if let replaced = state.preparedImages[imageIndex] {
            state.preparedByteCount -= replaced.prepared.byteCount
        }
        state.useCounter += 1
        state.preparedImages[imageIndex] = KeptPreparedImage(prepared: prepared, lastUse: state.useCounter)
        state.preparedByteCount += prepared.byteCount
        Self.evictLeastRecentlyUsedImages(from: &state, keeping: imageIndex)
    }

    private static func evictLeastRecentlyUsedImages(from state: inout State, keeping keptImageIndex: Int?) {
        var evictedImageIndices: [Int] = []
        while state.preparedByteCount > state.preparedByteLimit {
            guard let oldest = state.preparedImages.filter({ $0.key != keptImageIndex }).min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            state.preparedByteCount -= oldest.value.prepared.byteCount
            state.preparedImages[oldest.key] = nil
            evictedImageIndices.append(oldest.key)
        }
        releaseImageData(ofEvictedImagesAt: evictedImageIndices, in: &state)
    }

    /// Sets the most bytes of prepared images kept, dropping the least
    /// recently used past it; zero drops every one.
    func setPreparedByteLimit(_ byteLimit: Int) {
        state.withLock { state in
            state.preparedByteLimit = max(0, byteLimit)
            Self.evictLeastRecentlyUsedImages(from: &state, keeping: nil)
        }
    }

    /// Reads, once a generation, what the prefilters of a query across the
    /// indexed images read the first time — every image's load commands and
    /// export trie — in the background, behind the preparations queued
    /// before it, on one of the queue's threads. A query that needs it
    /// meanwhile waits for it rather than reading it again.
    func preparePrefiltersIfNeeded(with analyzer: CrossReferenceAnalyzer, generation: Int) {
        guard preparesPrefilters else { return }
        let shouldPrepare = state.withLock { state -> Bool in
            guard state.generation == generation, state.prefilterPreparationGeneration != generation else { return false }
            state.prefilterPreparationGeneration = generation
            return true
        }
        guard shouldPrepare else { return }
        let operation = BlockOperation { [weak self] in
            analyzer.preparePrefilters()
            self?.state.withLock { $0.preparedPrefilterGeneration = generation }
        }
        operation.queuePriority = .low
        scanQueue.addOperation(operation)
    }

    /// Has `analyzer` read the names of prepared images that an analyzer
    /// since renewed read them for, on the session's queue ahead of the
    /// preparations waiting, so that the first query naming what their
    /// indexes answer does not read them itself: AppKit's take 0.3 s in a
    /// debug build. An image dropped meanwhile, or an analyzer renewed again,
    /// reads nothing.
    private func readNames(ofImagesAt imageIndices: [Int], with analyzer: CrossReferenceAnalyzer, generation: Int) {
        for imageIndex in imageIndices {
            let operation = BlockOperation { [weak self] in
                guard let self, state.withLock({ $0.generation == generation && $0.preparedImages[imageIndex] != nil }) else { return }
                analyzer.prepareNames(inImageAt: imageIndex)
            }
            operation.queuePriority = .high
            scanQueue.addOperation(operation)
        }
    }

    /// The generation whose prefilters are read; for tests.
    var preparedPrefilterGeneration: Int? {
        state.withLock { $0.preparedPrefilterGeneration }
    }

    /// The images with a prepared image kept now; for tests.
    var preparedImageIndices: Set<Int> {
        state.withLock { Set($0.preparedImages.keys) }
    }

    /// The bytes of prepared images kept now; for tests.
    var preparedByteCount: Int {
        state.withLock { $0.preparedByteCount }
    }

    /// How many preparations started building; for tests.
    var startedPreparationCount: Int {
        state.withLock { $0.startedPreparationCount }
    }

    /// Whether a preparation is queued or under way; for tests.
    var hasPreparationsUnderWay: Bool {
        state.withLock { !$0.preparations.isEmpty }
    }

    /// One image's preparation, under one numbering of the images: the
    /// analyzers of every generation since a numbering began share it.
    private struct PreparationKey: Hashable {
        let imageIndex: Int
        /// The generation the numbering began with (`State.numberingGeneration`).
        let numbering: Int
    }

    /// A preparation queued or under way, and who waits for it.
    private struct Preparation {
        var operation: Operation
        /// The generation of the analyzer the preparation reads the image
        /// with, which keeps the names it reads.
        let buildGeneration: Int
        var waiters: [UUID: CheckedContinuation<CrossReferencePreparedImage, any Error>] = [:]
        var progressHandlers: [UUID: @Sendable (RuntimeCrossReferencePreparationProgress) async -> Void] = [:]
        /// Every requester left: the operation stops instead of building.
        var isAbandoned = false
    }

    private struct KeptPreparedImage {
        let prepared: CrossReferencePreparedImage
        var lastUse: UInt64
    }

    /// One image's scan for one key, in one generation.
    private struct InFlightScan: Hashable {
        let key: CrossReferenceScanKey
        let imageIndex: Int
        let generation: Int
    }

    private struct Scan {
        var referencesByImage: [Int: [CodeReference]] = [:]
        var byteCount = 0
        var lastUse: UInt64 = 0
    }

    private struct State {
        var analyzer: CrossReferenceAnalyzer?
        /// The images outside the shared cache the analyzer numbers, in
        /// dyld's order.
        var imagesOutsideSharedCache: [UInt] = []
        var imagesWithFunctionTables: Set<Int> = []
        /// Counts the analyzers made; each has its own function tables and
        /// names.
        var generation = 0
        /// The generation the analyzer's numbering of the images began with.
        /// An analyzer renewed for images loaded since keeps the numbering,
        /// so what was prepared or scanned with any analyzer since this
        /// generation still holds; starting over begins a new one.
        var numberingGeneration = 0
        var scans: [CrossReferenceScanKey: Scan] = [:]
        /// Scans found larger than the budget, which are not recorded again.
        var oversizedScanKeys: Set<CrossReferenceScanKey> = []
        var scanByteCount = 0
        var useCounter: UInt64 = 0
        var startedScanCount = 0
        /// The scans running now, which a query asking for the same waits for.
        var inFlightScans: [InFlightScan: Task<[CodeReference], Never>] = [:]
        /// The prepared images kept, by image, under the current numbering.
        var preparedImages: [Int: KeptPreparedImage] = [:]
        var preparedByteCount = 0
        var preparedByteLimit = CrossReferenceSession.defaultPreparedByteLimit
        var preparations: [PreparationKey: Preparation] = [:]
        var startedPreparationCount = 0
        /// The generation whose prefilters were asked to be read, and the one
        /// whose prefilters are.
        var prefilterPreparationGeneration: Int?
        var preparedPrefilterGeneration: Int?
    }
}

/// An image's prepared cross references, as the session keeps them: its
/// index, and the memory of what the analyzer keeps to name what the index
/// answers with — the image's function table and the names read for it —
/// which the byte limit counts along with the index: about two thirds again
/// for AppKit.
struct CrossReferencePreparedImage: Sendable {
    let index: CodeReferenceIndex
    let namingByteCount: Int

    var byteCount: Int {
        index.approximateByteCount + namingByteCount
    }
}

/// What a scan looked for: the key its findings are kept under.
enum CrossReferenceScanKey: Hashable, Sendable {
    /// The references filed under any of these keys: a callers query.
    case references(Set<CodeReferenceTable.Key>)
    /// The references to the class whose object lies at this location. Not
    /// the class's name: the macOS and the Mac Catalyst variant of a
    /// framework define classes of the same name.
    case objectiveCClass(CodeLocation)
    /// The references to the Swift type whose descriptor lies here.
    case swiftType(CodeLocation)
}

extension CrossReferenceQuery {
    /// A query against the process's session — what the commands run.
    init(engine: RuntimeEngine) {
        self.init(engine: engine, session: .shared)
    }
}

// MARK: - Logging

@Loggable(.private)
private enum CrossReferenceSessionLog {
    static func madeAnalyzer(generation: Int, imageCountOutsideSharedCache: Int) {
        #log(.info, "Made the cross-reference analyzer (generation \(generation, privacy: .public)) with \(imageCountOutsideSharedCache, privacy: .public) images outside the shared cache")
    }

    static func startedOver(generation: Int, droppedPreparedImageCount: Int) {
        #log(.info, "An image the cross-reference analyzer numbers was unloaded: started over (generation \(generation, privacy: .public)), dropping \(droppedPreparedImageCount, privacy: .public) prepared images")
    }

    static func renewedAnalyzer(generation: Int, loadedImageCount: Int, keptPreparedImageCount: Int) {
        #log(.info, "A query asked about an image loaded since: renewed the cross-reference analyzer (generation \(generation, privacy: .public)) for \(loadedImageCount, privacy: .public) images loaded outside the shared cache, keeping \(keptPreparedImageCount, privacy: .public) prepared images")
    }
}
