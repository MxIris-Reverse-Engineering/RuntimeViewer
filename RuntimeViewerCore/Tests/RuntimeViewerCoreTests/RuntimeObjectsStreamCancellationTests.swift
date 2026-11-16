#if canImport(Network) && os(macOS)

import Testing
import Foundation
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// What a consumer of `objectsWithProgress(in:)` that stops listening ends.
///
/// The sidebar reads an image's objects through this stream and drops it when
/// the user moves to another image or the list reloads. The stream's
/// producer is the request to the process serving the engine; left running,
/// it kept that request — and the engine's foreground load, which holds back
/// background indexing — until the whole image was built, with no one
/// listening (KnownIssues M6.1).
///
/// **A known issue, not fixed** (2026-11-16 audit, CA.11): cancelling the
/// producer cannot withdraw the request, because `ObjectsInImageCommand` does
/// not opt into `cancelsAcrossConnections` — a peer of an earlier release does
/// not know `cancelRequest`, and an injected payload reached over a Mach
/// service takes an unknown message for its client going away. Withdrawing it
/// needs the command enabled only for peers that know `cancelRequest`. The test
/// keeps the defect reproduced; once that lands, the known issue stops being
/// recorded and the test fails until the `withKnownIssue` is removed.
@Suite("Objects stream cancellation", .serialized)
struct RuntimeObjectsStreamCancellationTests {
    /// Large enough that building it takes the serving process far longer
    /// than `promptReturn`.
    private static let largeImagePath = "/System/Library/Frameworks/AppKit.framework/AppKit"

    private static let promptReturn: Duration = .seconds(2)

    private static func foregroundLoadCount(of engine: RuntimeEngine) async -> Int {
        let manager = await engine.backgroundIndexingManager
        return await manager.foregroundLoadCount
    }

    @Test("A consumer that stops listening ends the forwarded load, and the engine's foreground load with it")
    func cancellingTheConsumerEndsTheLoad() async throws {
        let serving = try await RemoteEnginePair.makeServingEngine(label: "objects-stream-cancellation", loading: [])
        let pair = try await RemoteEnginePair.make(.socket, label: "objects-stream-cancellation.socket", serving: serving)
        defer { Task { await pair.stop() } }
        try #require(try await !pair.serving.isImageIndexed(path: Self.largeImagePath), "the image is already built, so its load would end at once anyway")

        let progress = MarkedEventCounter()
        let consumer = Task {
            for try await event in await pair.client.objectsWithProgress(in: Self.largeImagePath) {
                if case .progress = event {
                    progress.record()
                }
            }
        }
        let didStart = await waitForCondition(timeout: .seconds(60)) { progress.count > 0 }
        try #require(didStart, "the load never reported progress")
        #expect(await Self.foregroundLoadCount(of: pair.client) == 1)

        consumer.cancel()

        let endedPromptly = await waitForCondition(timeout: Self.promptReturn) {
            await Self.foregroundLoadCount(of: pair.client) == 0
        }
        // Only meaningful while the serving process is still building the
        // image: once it is done, the load ends whether or not it was cancelled.
        let servingStillBuilding = try await !pair.serving.isImageIndexed(path: Self.largeImagePath)
        try #require(servingStillBuilding, "the serving process finished the image within \(Self.promptReturn); use a larger one")
        withKnownIssue("ObjectsInImageCommand cannot be withdrawn across connections (CA.11)") {
            #expect(endedPromptly, "the engine kept its foreground load for an image no one was listening for")
        }
    }
}

#endif
