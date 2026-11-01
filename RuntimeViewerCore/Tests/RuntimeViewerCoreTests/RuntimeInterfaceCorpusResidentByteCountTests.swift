#if os(macOS)
import Foundation
import Testing
@testable import RuntimeViewerCore

/// The corpus's resident budget weighs the byte counts its corpora estimate
/// against the limit, so an estimate that falls short lets the corpora hold
/// more than the user allowed. It used to count the text, the span table and
/// the members by their element counts alone — no allocation headers, none of
/// malloc's rounding, none of the visibility conditions — and evicting
/// Foundation's corpus gave back about a fifth more than it counted (proposal
/// `engine-resident-memory`).
///
/// Measured in a process of its own (an exit test), so that what other suites
/// allocate does not move the reading: the bytes malloc has handed out and not
/// taken back, before and after the corpus is evicted. An expectation that
/// fails in that process is reported here, with the numbers it measured.
@Suite("RuntimeInterfaceCorpus resident byte count")
struct RuntimeInterfaceCorpusResidentByteCountTests {
    @Test("a corpus's byte count is within a tenth of what evicting it frees")
    func byteCountMatchesWhatEvictionFrees() async {
        await #expect(processExitsWith: .success) {
            let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
            let engine = RuntimeEngine(source: .local, engineID: "test-corpus-resident-byte-count")
            try await engine.connect()
            try await engine.loadImage(at: "/usr/lib/libobjc.A.dylib")
            try await engine.loadImage(at: foundationPath)
            let summary = try await engine.buildInterfaceCorpus(for: foundationPath, transformer: .default)
            let allocatedBeforeEviction = allocatedByteCount()

            try await engine.evictInterfaceCorpus(for: foundationPath)

            let freedByteCount = allocatedBeforeEviction - allocatedByteCount()
            #expect(abs(summary.byteCount - freedByteCount) * 10 <= freedByteCount, "estimated \(summary.byteCount) bytes; evicting freed \(freedByteCount)")
            withExtendedLifetime(engine) {}
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
