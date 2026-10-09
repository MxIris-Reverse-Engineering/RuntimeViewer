import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// Which images the corpus coordinator hears of as they become indexed.
///
/// The sidebar lists an image's objects through `objects(in:)`, which indexes
/// an image dyld already has without loading it — the state of nearly every
/// image of an attached process, and of Foundation or AppKit on My Mac. The
/// coordinator listened only to the background indexer and to image loads,
/// so the image the user had open never became searchable (PR121.04).
@Suite("FindCorpusCoordinator indexed images", .serialized)
@MainActor
struct FindCorpusCoordinatorIndexedImageTests {
    @Test("an image the sidebar opens, already loaded, gets its corpus built")
    func imageOpenedInTheSidebarBecomesSearchable() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorIndexedImageTests.sidebarOpen")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }
        // The coordinator's catch-up over the images indexed when it started
        // has nothing to find, and is over before the image gets indexed.
        try await Task.sleep(for: .seconds(1))

        // The sidebar's path: list the objects of an image dyld already has.
        _ = try await engine.objects(in: TestImages.libobjc)

        let states = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 20) {
            $0[TestImages.libobjc]?.isBuilt == true
        }
        #expect(states[TestImages.libobjc]?.isBuilt == true)
        await engine.stop()
    }
}
