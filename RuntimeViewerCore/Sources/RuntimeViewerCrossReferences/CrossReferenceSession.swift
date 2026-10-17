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

    /// Images whose function tables an analyzer may hold before it is replaced
    /// by a fresh one. Naming a callee keeps its image's table; a table runs
    /// from kilobytes to a few megabytes, and a long session names functions
    /// in hundreds of images.
    static let functionTableImageLimit = 64

    private let scanByteBudget: Int
    /// The header address of every image loaded outside the shared cache —
    /// what decides whether an analyzer is still current. The process's
    /// own list, unless a test needs one that does not change under it: the
    /// Objective-C runtime loads `libobjc-trampolines.dylib`, which is not in
    /// the cache, the first time anything in the process needs it.
    private let imagesOutsideSharedCache: @Sendable () -> [UInt]
    private let state = Mutex(State())

    init(
        scanByteBudget: Int = CrossReferenceSession.defaultScanByteBudget,
        imagesOutsideSharedCache: @escaping @Sendable () -> [UInt] = CrossReferenceSession.processImagesOutsideSharedCache
    ) {
        self.scanByteBudget = scanByteBudget
        self.imagesOutsideSharedCache = imagesOutsideSharedCache
    }

    // MARK: - Analyzer

    /// The analyzer for the process's images as they are now, and the
    /// generation scans are filed under.
    ///
    /// An analyzer is a snapshot: images loaded outside the shared cache
    /// after it was made are not in it. When those have changed, a new
    /// analyzer replaces it, its image indices may differ, and the scans
    /// filed under the old generation are dropped.
    func currentAnalyzer() throws -> (analyzer: CrossReferenceAnalyzer, generation: Int) {
        let imagesOutsideSharedCache = self.imagesOutsideSharedCache()
        return try state.withLock { state in
            if let analyzer = state.analyzer, state.imagesOutsideSharedCache == imagesOutsideSharedCache {
                return (analyzer, state.generation)
            }
            guard let analyzer = CrossReferenceAnalyzer() else {
                throw RuntimeCrossReferenceError.unsupportedArchitecture
            }
            state.analyzer = analyzer
            state.imagesOutsideSharedCache = imagesOutsideSharedCache
            state.imagesWithFunctionTables = []
            state.generation += 1
            state.scans = [:]
            state.oversizedScanKeys = []
            state.scanByteCount = 0
            return (analyzer, state.generation)
        }
    }

    /// Records that a query had the analyzer name functions in
    /// `imageIndices`, which keeps their function tables; past
    /// ``functionTableImageLimit`` the analyzer is replaced by one over the
    /// same images, which drops them. The image indices stay the same, so the
    /// scans stay valid.
    func noteFunctionTables(ofImagesAt imageIndices: some Sequence<Int>, generation: Int) {
        state.withLock { state in
            guard state.generation == generation else { return }
            state.imagesWithFunctionTables.formUnion(imageIndices)
            guard state.imagesWithFunctionTables.count > Self.functionTableImageLimit,
                  let freshAnalyzer = CrossReferenceAnalyzer()
            else { return }
            state.analyzer = freshAnalyzer
            state.imagesWithFunctionTables = []
        }
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
    /// nothing found maps to an empty array.
    func scannedReferences(for key: CrossReferenceScanKey, generation: Int) -> [Int: [CodeReference]] {
        state.withLock { state in
            guard state.generation == generation, var scan = state.scans[key] else { return [:] }
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
            guard state.generation == generation, !state.oversizedScanKeys.contains(key) else { return }
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

    private struct Scan {
        var referencesByImage: [Int: [CodeReference]] = [:]
        var byteCount = 0
        var lastUse: UInt64 = 0
    }

    private struct State {
        var analyzer: CrossReferenceAnalyzer?
        var imagesOutsideSharedCache: [UInt] = []
        var imagesWithFunctionTables: Set<Int> = []
        var generation = 0
        var scans: [CrossReferenceScanKey: Scan] = [:]
        /// Scans found larger than the budget, which are not recorded again.
        var oversizedScanKeys: Set<CrossReferenceScanKey> = []
        var scanByteCount = 0
        var useCounter: UInt64 = 0
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
