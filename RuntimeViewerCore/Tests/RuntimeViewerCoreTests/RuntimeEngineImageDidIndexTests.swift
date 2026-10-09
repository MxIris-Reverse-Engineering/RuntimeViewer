#if canImport(Network) && os(macOS)

import Testing
import Foundation
import Combine
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// `RuntimeEngine.imageDidIndexPublisher`: the engine a caller holds reports
/// every image its own API indexed, under the caller's spelling of the path.
///
/// The sidebar lists an image's objects through `objects(in:)`, which indexes
/// an image dyld already has without loading it; nothing reported that, so
/// the corpus coordinator never heard of the image the user had open
/// (PR121.04).
@Suite("Image indexed reports", .serialized)
struct RuntimeEngineImageDidIndexTests {
    private static let libobjcPath = "/usr/lib/libobjc.A.dylib"

    private final class IndexedPathRecorder: @unchecked Sendable {
        private let lock = NSLock()

        private var recordedPaths: [String] = []

        private var subscription: AnyCancellable?

        init(listeningTo engine: RuntimeEngine) {
            subscription = engine.imageDidIndexPublisher.sink { [weak self] path in
                guard let self else { return }
                lock.lock()
                defer { lock.unlock() }
                recordedPaths.append(path)
            }
        }

        var paths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recordedPaths
        }
    }

    @Test("Listing an image's objects reports it, under the caller's path")
    func listingObjectsReportsTheImage() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "image-did-index.objects")
        try await engine.connect()
        defer { Task { await engine.stop() } }
        let recorder = IndexedPathRecorder(listeningTo: engine)

        _ = try await engine.objects(in: Self.libobjcPath)

        #expect(recorder.paths == [Self.libobjcPath])
    }

    @Test("Loading an image for the background indexer reports it")
    func backgroundIndexingLoadReportsTheImage() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "image-did-index.background")
        try await engine.connect()
        defer { Task { await engine.stop() } }
        let recorder = IndexedPathRecorder(listeningTo: engine)

        try await engine.loadImageForBackgroundIndexing(at: Self.libobjcPath)

        #expect(recorder.paths == [Self.libobjcPath])
    }

    @Test("A forwarding engine reports what its own requests indexed, with no message from the peer")
    func forwardingEngineReportsItsOwnRequests() async throws {
        let serving = try await RemoteEnginePair.makeServingEngine(label: "image-did-index.forwarding", loading: [])
        let pair = try await RemoteEnginePair.make(.xpcService, label: "image-did-index.forwarding", serving: serving)
        defer { Task { await pair.stop(); await serving.stop() } }
        let clientRecorder = IndexedPathRecorder(listeningTo: pair.client)

        _ = try await pair.client.objects(in: Self.libobjcPath)

        #expect(clientRecorder.paths == [Self.libobjcPath])
    }
}

#endif
