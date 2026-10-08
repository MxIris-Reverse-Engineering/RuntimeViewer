#if canImport(Network) && os(macOS)

import Testing
import Foundation
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// A path as the process that owns the images keys it.
///
/// A process in the iOS Simulator keys its images under its own
/// `DYLD_ROOT_PATH`, and the corpus commands report those keys, while the
/// sidebar, the background indexer and a search scope spell the same image
/// without the root. A client cannot work out the root itself — it belongs to
/// the serving process — so it asks for it (PR121.33).
@Suite("Image path canonicalization", .serialized)
struct RuntimeEngineImagePathCanonicalizationTests {
    private static let simulatorRootPath = "/sim_root"

    @Test("The serving root is prefixed once, and a path without a root is left alone")
    func canonicalizationAppliesTheRootOnce() {
        let engine = RuntimeEngine(source: .local, engineID: "image-path-canonicalization.pure")

        engine.setDyldRootPathForTesting(Self.simulatorRootPath)
        let canonicalPath = engine.canonicalImagePath("/usr/lib/libobjc.A.dylib")
        #expect(canonicalPath == "/sim_root/usr/lib/libobjc.A.dylib")
        #expect(engine.canonicalImagePath(canonicalPath) == canonicalPath, "canonicalization is not idempotent")
        #expect(engine.canonicalImagePath("relative/path") == "relative/path")

        engine.setDyldRootPathForTesting(nil)
        #expect(engine.canonicalImagePath("/usr/lib/libobjc.A.dylib") == "/usr/lib/libobjc.A.dylib")
    }

    @Test("A client over a socket learns the root of the process it forwards to")
    func socketClientLearnsTheServingRoot() async throws {
        let serving = try await RemoteEnginePair.makeServingEngine(label: "image-path-canonicalization.socket", loading: [])
        serving.setDyldRootPathForTesting(Self.simulatorRootPath)
        let pair = try await RemoteEnginePair.make(.socket, label: "image-path-canonicalization.socket", serving: serving)
        defer { Task { await pair.stop(); await serving.stop() } }

        let learned = await waitForCondition(timeout: .seconds(5)) {
            pair.client.canonicalImagePath("/usr/lib/libobjc.A.dylib") == "/sim_root/usr/lib/libobjc.A.dylib"
        }
        #expect(learned, "the client keys \(pair.client.canonicalImagePath("/usr/lib/libobjc.A.dylib"))")
    }

    /// An XPC peer is a Mac process, and an injected payload of an earlier
    /// release takes a command it does not know for its client leaving
    /// (PR121.73), so an XPC client never asks — even when, as here, the
    /// peer would have an answer.
    @Test("A client over XPC never asks, and keys paths as they are")
    func xpcClientNeverAsks() async throws {
        let serving = try await RemoteEnginePair.makeServingEngine(label: "image-path-canonicalization.xpc", loading: [])
        serving.setDyldRootPathForTesting(Self.simulatorRootPath)
        let pair = try await RemoteEnginePair.make(.xpcService, label: "image-path-canonicalization.xpc", serving: serving)
        defer { Task { await pair.stop(); await serving.stop() } }

        try await Task.sleep(for: .milliseconds(500))
        #expect(pair.client.canonicalImagePath("/usr/lib/libobjc.A.dylib") == "/usr/lib/libobjc.A.dylib")
    }

    @Test("A peer that does not know the question neither holds the connection up nor changes a path")
    func peerWithoutTheCommandLeavesPathsAlone() async throws {
        // Serves no command at all, the way a release older than the question
        // answers it: "No handler registered for …".
        let olderPeer = try await RuntimeDirectTCPServerConnection(port: 0, waitForConnection: false)
        let client = RuntimeEngine(
            source: .directTCP(name: "image-path-canonicalization.older", host: "127.0.0.1", port: olderPeer.port, role: .client),
            engineID: "image-path-canonicalization.older"
        )
        defer { Task { await client.stop(); olderPeer.stop() } }

        let connectStartedAt = ContinuousClock.now
        try await client.connect()
        #expect(ContinuousClock.now - connectStartedAt < .seconds(1), "connecting waited for an answer that never comes")

        try await Task.sleep(for: .seconds(2))
        #expect(client.canonicalImagePath("/usr/lib/libobjc.A.dylib") == "/usr/lib/libobjc.A.dylib")
    }
}

#endif
