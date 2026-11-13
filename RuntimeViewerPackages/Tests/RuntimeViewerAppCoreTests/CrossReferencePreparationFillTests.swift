#if canImport(Network)

import Foundation
import Testing
@testable import RuntimeViewerCore
@testable import RuntimeViewerCrossReferences
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport
@testable import RuntimeViewerSettings

/// Keep Cross References Ready fills the resident limit and evicts nothing for it: every image is
/// asked for to be kept only within the room left, the Always Index ones first, and the first that
/// does not fit stops the preparations until something makes room (proposal
/// `on-demand-corpora-and-cross-references`).
@Suite("Cross-reference preparations filling the resident limit", .serialized)
@MainActor
struct CrossReferencePreparationFillTests {
    private nonisolated static let keptImagePath = "/Scripted/libA.dylib"
    private nonisolated static let unkeptImagePath = "/Scripted/libB.dylib"
    private nonisolated static let heldImagePath = "/Scripted/libC.dylib"
    private nonisolated static let laterImagePath = "/Scripted/libD.dylib"

    @Test("the first image not kept stops the preparations, withdrawing those still open, until Eject makes room")
    func firstImageNotKeptStopsThePreparations() async throws {
        let peer = try await ScriptedPeer.make(label: "CrossReferencePreparationFillTests.stop")
        defer { Task { await peer.stop() } }
        let requests = RecordedFillRequests()
        let heldPreparations = HeldRequests()
        Self.serveEverythingButPreparation(on: peer, indexedImagePaths: [])
        peer.serve(.crossReferencePrepare, reading: PreparationEnvelope.self) { envelope in
            let imagePath = envelope.request.imagePath
            await requests.record(imagePath, evictsNothing: envelope.request.options.evictsNothing)
            switch imagePath {
            case Self.keptImagePath:
                return RuntimeCrossReferencePreparationOutcome.prepared(RuntimeCrossReferencePreparation(referenceCount: 1, byteCount: 10))
            case Self.unkeptImagePath:
                return .prepared(RuntimeCrossReferencePreparation(referenceCount: 1, byteCount: 10, isKept: false))
            default:
                await heldPreparations.hold()
                return .cancelled
            }
        }
        let environment = Self.makeEnvironment(on: peer.client)
        let coordinator = environment.make { CrossReferencePreparationCoordinator(engine: peer.client) }
        defer { withExtendedLifetime(coordinator) {} }

        // One by one, as the engine reports images indexed: one kept, one still being prepared,
        // then one that does not fit.
        coordinator.requestPreparation(of: Self.keptImagePath)
        try await waitUntil(timeout: 10) { coordinator.preparationStatesByImagePath[Self.keptImagePath]?.isPrepared == true }
        coordinator.requestPreparation(of: Self.heldImagePath)
        try await requests.waitUntilRecorded(Self.heldImagePath)
        coordinator.requestPreparation(of: Self.unkeptImagePath)

        try await waitUntil(timeout: 10) { coordinator.isResidentLimitFull }
        #expect(coordinator.preparationStatesByImagePath[Self.keptImagePath]?.isPrepared == true)
        #expect(coordinator.preparationStatesByImagePath[Self.unkeptImagePath] == nil)
        #expect(coordinator.preparationStatesByImagePath[Self.heldImagePath] == nil, "withdrawn")
        #expect(coordinator.followedImagePaths.isEmpty)
        #expect(coordinator.finishedPreparations.contains { finishedPreparation in
            if case .notKept = finishedPreparation.outcome { return finishedPreparation.imagePath == Self.unkeptImagePath }
            return false
        })
        #expect(await requests.evictsNothingValues == [true, true, true], "every image asked to be kept only within the room left")

        // Full: an image indexed now is left to the queries.
        coordinator.requestPreparation(of: Self.laterImagePath)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await !requests.imagePaths.contains(Self.laterImagePath))

        // Eject makes room: the next image is asked for again.
        coordinator.ejectPreparations()
        #expect(!coordinator.isResidentLimitFull)
        coordinator.requestPreparation(of: Self.laterImagePath)
        try await requests.waitUntilRecorded(Self.laterImagePath)
        await heldPreparations.release()
    }

    @Test("the images indexed at once are asked for in the order of the Always Index rows, the others after them by path")
    func preparationOrderFollowsTheAlwaysIndexRows() async throws {
        let peer = try await ScriptedPeer.make(label: "CrossReferencePreparationFillTests.order")
        defer { Task { await peer.stop() } }
        Self.serveEverythingButPreparation(on: peer, indexedImagePaths: [])
        let environment = Self.makeEnvironment(on: peer.client)
        let coordinator = environment.make { CrossReferencePreparationCoordinator(engine: peer.client) }
        defer { withExtendedLifetime(coordinator) {} }

        coordinator.noteAlwaysIndexImagePaths([Self.heldImagePath, Self.keptImagePath])
        // A later pass keeps the places already taken.
        coordinator.noteAlwaysIndexImagePaths([Self.unkeptImagePath, Self.heldImagePath])

        let otherImagePaths = ["/Scripted/libZ.dylib", "/Scripted/libE.dylib"]
        let order = coordinator.preparationOrder(of: otherImagePaths + [Self.unkeptImagePath, Self.keptImagePath, Self.heldImagePath])
        #expect(order == [Self.heldImagePath, Self.keptImagePath, Self.unkeptImagePath, "/Scripted/libE.dylib", "/Scripted/libZ.dylib"])
    }

    /// Cross-reference preparation on, corpora and background indexing off.
    private static func makeEnvironment(on engine: RuntimeEngine) -> ViewModelTestEnvironment {
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.indexing.isEnabled = false
        environment.settings.search.isCorpusEnabled = false
        environment.settings.search.isCrossReferencePreparationEnabled = true
        return environment
    }

    private static func serveEverythingButPreparation(on peer: ScriptedPeer, indexedImagePaths: [String]) {
        peer.serve(.interfaceCorpusCoverage) { RuntimeInterfaceCorpusCoverage.empty }
        peer.serve(.indexedImagePaths) { indexedImagePaths }
        peer.serve(.crossReferenceSetPreparedByteLimit) { RuntimeEngineEmpty() }
        peer.serve(.crossReferencePreparedByteCount) { 0 }
    }

    /// The parts of a preparation request the test reads, in the progress envelope it travels in.
    private struct PreparationEnvelope: Codable {
        struct Request: Codable {
            struct Options: Codable {
                let evictsNothing: Bool?
            }

            let imagePath: String
            let options: Options
        }

        let request: Request
    }
}

private actor RecordedFillRequests {
    private(set) var imagePaths: [String] = []

    private(set) var evictsNothingValues: [Bool?] = []

    func record(_ imagePath: String, evictsNothing: Bool?) {
        imagePaths.append(imagePath)
        evictsNothingValues.append(evictsNothing)
    }

    func waitUntilRecorded(_ imagePath: String, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !imagePaths.contains(imagePath) {
            guard Date() < deadline else { throw FillRequestNotHeard(imagePath: imagePath, imagePaths: imagePaths) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct FillRequestNotHeard: Swift.Error, CustomStringConvertible {
    let imagePath: String
    let imagePaths: [String]

    var description: String { "the engine was never asked to prepare \(imagePath); it was asked for \(imagePaths)" }
}

#endif
