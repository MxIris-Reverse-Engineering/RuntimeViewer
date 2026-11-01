#if arch(arm64) && os(macOS)
import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerCrossReferences

/// Keep Cross References Ready keeps prepared images within a byte limit,
/// weighing what each image's preparation estimates against it, so an
/// estimate that falls short lets the prepared images hold more than the user
/// allowed (proposal `engine-resident-memory`).
///
/// Measured in a process of its own (an exit test), so that what other suites
/// allocate does not move the reading: the bytes malloc has handed out and not
/// taken back, before and after the limit drops to zero, which lets go of the
/// image's index and of the names read for it. An expectation that fails in
/// that process is reported here, with the numbers it measured.
@Suite("Prepared cross references byte count")
struct CrossReferencePreparedByteCountTests {
    @Test("a prepared image's byte count is within a tenth of what dropping it frees")
    func byteCountMatchesWhatDroppingFrees() async {
        await #expect(processExitsWith: .success) {
            let foundationPath = "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"
            let session = CrossReferenceSession(maximumConcurrentScans: ProcessInfo.processInfo.activeProcessorCount, preparesPrefilters: false, imagesOutsideSharedCache: { [] })
            let query = CrossReferenceQuery(engine: RuntimeEngine(source: .local, engineID: "test-cross-reference-prepared-byte-count"), session: session) { [foundationPath] }
            let options = RuntimeCrossReferencePreparationOptions(residentByteLimit: CrossReferenceSession.defaultPreparedByteLimit)
            let preparation = try await query.prepare(imageAt: foundationPath, options: options) { _ in }
            let allocatedBeforeDropping = allocatedByteCount()

            session.setPreparedByteLimit(0)

            let freedByteCount = allocatedBeforeDropping - allocatedByteCount()
            // The estimate is MachOSwiftSection's: CrossReferenceAnalysis's
            // `CodeReferenceIndex.approximateByteCount` and the analyzer's
            // `approximateByteCount(ofImageDataAt:)` count elements, but no
            // allocation headers and none of malloc's rounding — 17.6 MB
            // against the 19.9 MB Foundation's prepared image frees
            // (2026-11-01). Once they count those, this stops being a known
            // issue and the wrapper reports it.
            withKnownIssue("the prepared image's estimate falls about a tenth short of what it frees; it is computed in MachOSwiftSection") {
                #expect(abs(preparation.byteCount - freedByteCount) * 10 <= freedByteCount, "estimated \(preparation.byteCount) bytes; dropping freed \(freedByteCount)")
            }
            withExtendedLifetime(session) {}
        }
    }
}

/// The bytes malloc has handed out in this process and not taken back, over
/// all of its zones.
private func allocatedByteCount() -> Int {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return statistics.size_in_use
}
#endif
