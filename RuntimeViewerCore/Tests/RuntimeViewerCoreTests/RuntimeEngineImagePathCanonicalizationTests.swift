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

    /// As long as the client itself waits for an answer: a peer under load —
    /// a full parallel run — answers late, and the wait ends as soon as the
    /// root is learned.
    private static let answerWaitLimit = Duration.seconds(RuntimeEngine.servingDyldRootPathDeadline)

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

        let learned = await waitForCondition(timeout: Self.answerWaitLimit) {
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

    /// A peer that knows the question can still be slow to answer it: under
    /// load its reply queues behind the pushes a fresh connection sends. A
    /// slow answer is not a missing one, so the client keeps waiting for it —
    /// it used to give up for good after 3 seconds — and does not ask again
    /// for its taking long.
    @Test("A client keeps waiting for a peer that is slow to answer")
    func slowPeerIsWaitedFor() async throws {
        let slowPeer = try await RuntimeDirectTCPServerConnection(port: 0, waitForConnection: false)
        let client = RuntimeEngine(
            source: .directTCP(name: "image-path-canonicalization.slow", host: "127.0.0.1", port: slowPeer.port, role: .client),
            engineID: "image-path-canonicalization.slow"
        )
        defer { Task { await client.stop(); slowPeer.stop() } }
        let answeredQuestions = AnsweredQuestionCounter()

        try await client.connect()
        // The TCP server has no connection to mount a handler on until the
        // client connects; a question that comes first is answered "No
        // handler registered" and asked again.
        #expect(await waitForCondition { slowPeer.state == .connected })
        slowPeer.setMessageHandler(name: RuntimeEngine.DyldRootPathCommand.commandName) { (_: RuntimeEngine.DyldRootPathCommand) -> String? in
            answeredQuestions.increment()
            try await Task.sleep(for: .seconds(4))
            return Self.simulatorRootPath
        }

        let learned = await waitForCondition(timeout: Self.answerWaitLimit) {
            client.canonicalImagePath("/usr/lib/libobjc.A.dylib") == "/sim_root/usr/lib/libobjc.A.dylib"
        }
        #expect(learned, "the client keys \(client.canonicalImagePath("/usr/lib/libobjc.A.dylib")) after its peer answered")
        #expect(answeredQuestions.count == 1, "a slow peer was asked again")
    }

    /// A proxy installs its command table only once a client has connected,
    /// and answers "No handler registered" until then — for as long as a busy
    /// process takes to get there. The client used to give up after four such
    /// answers, a quarter of a second apart.
    @Test("A client keeps asking a peer whose answer is not in place yet")
    func lateCommandTableIsAskedAgain() async throws {
        let latePeer = try await RuntimeDirectTCPServerConnection(port: 0, waitForConnection: false)
        let client = RuntimeEngine(
            source: .directTCP(name: "image-path-canonicalization.late", host: "127.0.0.1", port: latePeer.port, role: .client),
            engineID: "image-path-canonicalization.late"
        )
        defer { Task { await client.stop(); latePeer.stop() } }

        try await client.connect()
        #expect(await waitForCondition { latePeer.state == .connected })
        try await Task.sleep(for: .milliseconds(1500))
        latePeer.setMessageHandler(name: RuntimeEngine.DyldRootPathCommand.commandName) { (_: RuntimeEngine.DyldRootPathCommand) -> String? in
            Self.simulatorRootPath
        }

        let learned = await waitForCondition(timeout: Self.answerWaitLimit) {
            client.canonicalImagePath("/usr/lib/libobjc.A.dylib") == "/sim_root/usr/lib/libobjc.A.dylib"
        }
        #expect(learned, "the client keys \(client.canonicalImagePath("/usr/lib/libobjc.A.dylib")) after its peer could answer")
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

/// How many times a peer's handler was reached, from the handler's task.
private final class AnsweredQuestionCounter: @unchecked Sendable {
    private let lock = NSLock()

    private var storedCount = 0

    var count: Int {
        lock.withLock { storedCount }
    }

    func increment() {
        lock.withLock { storedCount += 1 }
    }
}

#endif
