#if canImport(Network)

import Foundation
import Testing
@testable import RuntimeViewerCore
@testable import RuntimeViewerCrossReferences
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// The windows on one engine share its prepared cross references: the engine's
/// process prepares an image once, however many windows are open on the engine.
/// A second window joins the preparations the first one asked for instead of
/// asking again (proposal `engine-resident-memory`).
@Suite("Cross references shared by the windows on an engine", .serialized)
@MainActor
struct CrossReferencePreparationSharedByEngineTests {
    private nonisolated static let imagePath = "/Scripted/libShared.dylib"

    @Test("a second window on an engine asks its process to prepare nothing again")
    func secondWindowPreparesNothingAgain() async throws {
        let peer = try await ScriptedPeer.make(label: "CrossReferencePreparationSharedByEngineTests.secondWindow")
        defer { Task { await peer.stop() } }
        let preparationRequests = RecordedPreparationRequests()
        // Held, so the first window's preparation is still under way as the
        // second window opens.
        let heldPreparations = HeldRequests()
        peer.serve(.interfaceCorpusCoverage) { RuntimeInterfaceCorpusCoverage.empty }
        peer.serve(.indexedImagePaths) { [Self.imagePath] }
        peer.serve(.crossReferenceSetPreparedByteLimit) { RuntimeEngineEmpty() }
        peer.serve(.crossReferencePrepare, reading: PreparationEnvelope.self) { envelope in
            await preparationRequests.record(envelope.request.imagePath)
            await heldPreparations.hold()
            return RuntimeCrossReferencePreparationOutcome.cancelled
        }
        let firstEnvironment = Self.makeEnvironment(on: peer.client)
        firstEnvironment.startBackgroundWork()
        defer { withExtendedLifetime(firstEnvironment) {} }
        try await preparationRequests.waitUntilCount(isAtLeast: 1)

        let secondEnvironment = Self.makeEnvironment(on: peer.client)
        secondEnvironment.startBackgroundWork()
        defer { withExtendedLifetime(secondEnvironment) {} }
        // Long enough for a second window's own start to reach the peer.
        try await Task.sleep(for: .seconds(1))

        let requestedImagePaths = await preparationRequests.imagePaths
        #expect(requestedImagePaths == [Self.imagePath], "the engine was asked to prepare \(requestedImagePaths)")
        await heldPreparations.release()
    }

    /// Cross-reference preparation on, corpora and background indexing off:
    /// the only preparations are the cross-reference coordinator's.
    private static func makeEnvironment(on engine: RuntimeEngine) -> ViewModelTestEnvironment {
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.indexing.isEnabled = false
        environment.settings.search.isCorpusEnabled = false
        environment.settings.search.isCrossReferencePreparationEnabled = true
        return environment
    }

    /// The part of a preparation request the test reads: the progress
    /// envelope it travels in, around the command's image path.
    private struct PreparationEnvelope: Codable {
        struct Request: Codable {
            let imagePath: String
        }

        let request: Request
    }
}

private actor RecordedPreparationRequests {
    private(set) var imagePaths: [String] = []

    func record(_ imagePath: String) {
        imagePaths.append(imagePath)
    }

    func waitUntilCount(isAtLeast expectedCount: Int, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while imagePaths.count < expectedCount {
            guard Date() < deadline else { throw PreparationRequestsNotHeard(imagePaths: imagePaths) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct PreparationRequestsNotHeard: Swift.Error, CustomStringConvertible {
    let imagePaths: [String]

    var description: String { "the engine was never asked to prepare enough; it was asked for \(imagePaths)" }
}

#endif
