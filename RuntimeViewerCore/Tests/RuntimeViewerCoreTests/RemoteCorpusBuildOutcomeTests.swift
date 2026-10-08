#if canImport(Network) && os(macOS)

import Testing
import Foundation
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// A corpus build that ends without a summary, as a caller across a
/// connection sees it.
///
/// The corpus store gives a build up for every subscriber at once — another
/// window changed the transformer, the corpus switch went off — and each
/// subscriber is told with a `CancellationError`. A thrown error crosses a
/// connection as its description only, so a forwarding caller used to
/// receive a transport failure instead, and the Report navigator recorded a
/// failed build that never failed (PR121.30).
@Suite("Remote corpus build outcome", .serialized)
struct RemoteCorpusBuildOutcomeTests {
    private static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"

    /// The engine every pair of this suite serves, Foundation indexed once.
    private static let servingEngine = Task<RuntimeEngine, Swift.Error> {
        try await RemoteEnginePair.makeServingEngine(label: "remote-corpus-build-outcome", loading: [foundationPath])
    }

    @Test("A build the store gives up arrives at a forwarding caller as a cancellation", arguments: RemoteEnginePair.Transport.allCases)
    func storeCancellationCrossesTheConnection(transport: RemoteEnginePair.Transport) async throws {
        let pair = try await RemoteEnginePair.make(transport, label: "remote-corpus-build-outcome.store.\(transport)", serving: Self.servingEngine.value)
        defer { Task { await pair.stop() } }

        let progress = MarkedEventCounter()
        let build = Task {
            try await pair.client.buildInterfaceCorpus(for: Self.foundationPath, transformer: .default) { _ in
                progress.record()
            }
        }
        let didStart = await waitForCondition(timeout: .seconds(60)) { progress.count > 0 }
        try #require(didStart, "the build never reported progress")

        // What a transformer change in another window does: the store cancels
        // the build for every subscriber.
        try await pair.serving.evictInterfaceCorpus(for: nil)

        let result = await build.result
        #expect(throws: CancellationError.self) { try result.get() }
    }
}

#endif
