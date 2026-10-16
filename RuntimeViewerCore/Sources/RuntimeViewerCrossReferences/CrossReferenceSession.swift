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
    /// The process's session.
    fileprivate static let shared = CrossReferenceSession()

    /// Bytes of scan results kept between queries. A scan larger than this —
    /// the callers of `init` — is not kept, and every query for it scans again.
    static let defaultScanByteBudget = 64 << 20

    /// Images whose function tables an analyzer may hold before it is replaced
    /// by a fresh one. Naming a callee keeps its image's table; a table runs
    /// from kilobytes to a few megabytes, and a long session names functions
    /// in hundreds of images.
    static let functionTableImageLimit = 64

    private let scanByteBudget: Int
    private let state = Mutex(State())

    init(scanByteBudget: Int = CrossReferenceSession.defaultScanByteBudget) {
        self.scanByteBudget = scanByteBudget
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
        let imagesOutsideSharedCache = Self.imagesOutsideSharedCache()
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
    /// dyld's order — what decides whether an analyzer is still current.
    private static func imagesOutsideSharedCache() -> [UInt] {
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

    /// What earlier scans for `keys` found, by image — an image scanned with
    /// nothing found maps to an empty array.
    func scannedReferences(for keys: Set<CodeReferenceTable.Key>, generation: Int) -> [Int: [CodeReference]] {
        state.withLock { state in
            guard state.generation == generation, var scan = state.scans[keys] else { return [:] }
            state.useCounter += 1
            scan.lastUse = state.useCounter
            state.scans[keys] = scan
            return scan.referencesByImage
        }
    }

    /// Files what a scan for `keys` found in one image.
    func record(_ references: [CodeReference], for keys: Set<CodeReferenceTable.Key>, inImageAt imageIndex: Int, generation: Int) {
        let byteCount = references.count * MemoryLayout<CodeReference>.stride + MemoryLayout<Int>.stride * 4
        state.withLock { state in
            guard state.generation == generation else { return }
            state.useCounter += 1
            var scan = state.scans[keys] ?? Scan()
            guard scan.referencesByImage[imageIndex] == nil else { return }
            guard scan.byteCount + byteCount <= scanByteBudget else {
                // Larger than everything this session may keep: never kept,
                // and what was kept of it so far goes too.
                state.scanByteCount -= scan.byteCount
                state.scans[keys] = nil
                return
            }
            scan.referencesByImage[imageIndex] = references
            scan.byteCount += byteCount
            scan.lastUse = state.useCounter
            state.scans[keys] = scan
            state.scanByteCount += byteCount
            evictLeastRecentlyUsedScans(from: &state, keeping: keys)
        }
    }

    private func evictLeastRecentlyUsedScans(from state: inout State, keeping keptKeys: Set<CodeReferenceTable.Key>) {
        while state.scanByteCount > scanByteBudget {
            guard let oldest = state.scans.filter({ $0.key != keptKeys }).min(by: { $0.value.lastUse < $1.value.lastUse }) else { return }
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
        var scans: [Set<CodeReferenceTable.Key>: Scan] = [:]
        var scanByteCount = 0
        var useCounter: UInt64 = 0
    }
}

extension CrossReferenceQuery {
    /// A query against the process's session — what the commands run.
    init(engine: RuntimeEngine) {
        self.init(engine: engine, session: .shared)
    }
}
