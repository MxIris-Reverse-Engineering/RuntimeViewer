import Testing
import Foundation
@testable import RuntimeViewerCore

/// A corpus is printed from the sections the engine already built for an
/// image; asking for the corpus of an image that is not indexed must not
/// index it.
///
/// It used to: the corpus listed the image's objects through the call that
/// builds the sections, so a request for an unindexed image indexed it at
/// utility priority outside both indexing schedulers, one for an image that is
/// not loaded failed and stayed failed, and one for a path dyld does not know
/// indexed a same-named image under that path through the section factories'
/// file-name fallback (PR121.32). All three run in process: the defect is in
/// the engine's local arm, whatever transport leads there.
@Suite("Corpus builds only for indexed images", .serialized)
struct RuntimeInterfaceCorpusEligibilityTests {
    private static func makeEngine(_ engineID: String) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: engineID)
        try await engine.connect()
        return engine
    }

    @Test("A path dyld does not know is not indexed under a same-named image")
    func unknownPathIsNotIndexedByFileName() async throws {
        let engine = try await Self.makeEngine("corpus-eligibility.file-name")
        defer { Task { await engine.stop() } }
        // The file name of libobjc, which the section factories' fallback
        // finds among the images dyld has loaded.
        let unknownPath = "/tmp/NoSuchDirectory/libobjc.A.dylib"

        await #expect(throws: RuntimeInterfaceCorpusBuildError.imageNotIndexed(imagePath: unknownPath)) {
            _ = try await engine.buildInterfaceCorpus(for: unknownPath, transformer: .default)
        }
        let coverage = try await engine.interfaceCorpusCoverage()
        #expect(coverage.statesByImagePath[unknownPath] == nil, "the corpus store keeps \(String(describing: coverage.statesByImagePath[unknownPath])) for a path dyld does not know")
        #expect(try await engine.isImageIndexed(path: unknownPath) == false, "the corpus request indexed a same-named image under the unknown path")
    }

    @Test("A loaded image that is not indexed stays unindexed")
    func loadedButUnindexedImageStaysUnindexed() async throws {
        let engine = try await Self.makeEngine("corpus-eligibility.loaded")
        defer { Task { await engine.stop() } }
        let libobjcPath = "/usr/lib/libobjc.A.dylib"

        await #expect(throws: RuntimeInterfaceCorpusBuildError.imageNotIndexed(imagePath: libobjcPath)) {
            _ = try await engine.buildInterfaceCorpus(for: libobjcPath, transformer: .default)
        }
        #expect(try await engine.isImageIndexed(path: libobjcPath) == false, "the corpus request indexed the image")
    }

    @Test("An image that is not loaded leaves no failed state behind")
    func unloadedImageLeavesNoFailure() async throws {
        let engine = try await Self.makeEngine("corpus-eligibility.unloaded")
        defer { Task { await engine.stop() } }
        let unloadedPath = "/System/Library/Frameworks/GameController.framework/GameController"
        try #require(!DyldUtilities.imageNames().contains(unloadedPath), "the test process has GameController loaded; pick another framework it does not load")

        await #expect(throws: RuntimeInterfaceCorpusBuildError.imageNotIndexed(imagePath: unloadedPath)) {
            _ = try await engine.buildInterfaceCorpus(for: unloadedPath, transformer: .default)
        }
        let coverage = try await engine.interfaceCorpusCoverage()
        #expect(coverage.statesByImagePath[unloadedPath] == nil, "the corpus store keeps \(String(describing: coverage.statesByImagePath[unloadedPath])) for an image that is not loaded")
    }
}
