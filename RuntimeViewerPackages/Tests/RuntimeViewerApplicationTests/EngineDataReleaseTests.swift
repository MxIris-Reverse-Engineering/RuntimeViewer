#if canImport(Network)

import Foundation
import Testing
@testable import RuntimeViewerCore
@testable import RuntimeViewerCrossReferences
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// What the engine's process keeps for the documents on an engine — every
/// image's Find corpus, every image's prepared cross references — stayed there
/// after the last of them left, until the app quit: about 400 MB in the Mac
/// Catalyst engine's process of a Debug run and 300 MB in the local one's
/// (proposal `engine-resident-memory`). The last document leaving now has the
/// process drop them; a document joining while that is under way asks for them
/// again once it is done, so a late eviction cannot leave it without corpora
/// nor a late zero limit without prepared cross references.
@Suite("Engine data released when the last document leaves", .serialized)
@MainActor
struct EngineDataReleaseTests {
    /// What the test settings keep of prepared cross references: the default.
    private nonisolated static let preparedByteLimit = Settings.Search.default.crossReferenceResidentByteLimit

    @Test("the last document leaving an engine has its process drop the corpora and the prepared cross references")
    func lastDocumentLeavingReleasesTheEngineData() async throws {
        let peer = try await ScriptedPeer.make(label: "EngineDataReleaseTests.release")
        defer { Task { await peer.stop() } }
        let requests = RecordedEngineRequests()
        Self.serveBackgroundWork(on: peer, recordingInto: requests)
        let environment = Self.makeEnvironment(on: peer.client)
        environment.startBackgroundWork()
        _ = try await requests.waitUntil { $0.contains(.preparedCrossReferenceByteLimit(Self.preparedByteLimit)) }

        environment.make { environment.documentState.documentWillClose() }

        let heard = try await requests.waitUntil { requests in
            requests.contains(.corpusEviction(imagePath: nil)) && requests.contains(.preparedCrossReferenceByteLimit(0))
        }
        #expect(heard.contains(.corpusEviction(imagePath: nil)), "the engine heard: \(heard)")
        #expect(heard.contains(.preparedCrossReferenceByteLimit(0)), "the engine heard: \(heard)")
    }

    @Test("a document joining while the release is under way asks for the engine's data again once it is done")
    func documentJoiningDuringTheReleaseAsksAgain() async throws {
        let peer = try await ScriptedPeer.make(label: "EngineDataReleaseTests.rejoin")
        defer { Task { await peer.stop() } }
        let requests = RecordedEngineRequests()
        let heldEvictions = HeldRequests()
        Self.serveBackgroundWork(on: peer, recordingInto: requests, holdingEvictionsWith: heldEvictions)
        let firstEnvironment = Self.makeEnvironment(on: peer.client)
        firstEnvironment.startBackgroundWork()
        _ = try await requests.waitUntil { $0.contains(.preparedCrossReferenceByteLimit(Self.preparedByteLimit)) }
        firstEnvironment.make { firstEnvironment.documentState.documentWillClose() }
        _ = try await requests.waitUntil { $0.contains(.corpusEviction(imagePath: nil)) }

        // The eviction is held, so the release is still under way as the
        // second document starts. Its own start is heard before the hold is
        // let go, so what comes after can only be the asking again.
        let secondEnvironment = Self.makeEnvironment(on: peer.client)
        secondEnvironment.startBackgroundWork()
        defer { withExtendedLifetime(secondEnvironment) {} }
        _ = try await requests.waitUntil { requests in
            requests.count(of: .preparedCrossReferenceByteLimit(Self.preparedByteLimit)) == 2 && requests.count(where: \.isCorpusResidentByteLimit) == 2
        }
        await requests.record(.evictionLetGo)
        await heldEvictions.release()

        let heard = try await requests.waitUntil { requests in
            let afterTheRelease = requests.drop { $0 != .evictionLetGo }
            return afterTheRelease.contains(.preparedCrossReferenceByteLimit(Self.preparedByteLimit)) && afterTheRelease.contains(where: \.isCorpusResidentByteLimit)
        }
        let afterTheRelease = heard.drop { $0 != .evictionLetGo }
        // The last limit is the one the engine's process keeps.
        let lastPreparedByteLimit = afterTheRelease.last(where: \.isPreparedCrossReferenceByteLimit)
        #expect(lastPreparedByteLimit == .preparedCrossReferenceByteLimit(Self.preparedByteLimit), "the engine heard: \(heard)")
        let corpusCoordinatorStartedOver = afterTheRelease.contains(where: \.isCorpusResidentByteLimit)
        #expect(corpusCoordinatorStartedOver, "the corpus coordinator did not start over: \(heard)")
    }

    // MARK: - Support

    /// Corpora and prepared cross references on, background indexing off:
    /// the only requests are the two coordinators'.
    private static func makeEnvironment(on engine: RuntimeEngine) -> ViewModelTestEnvironment {
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.indexing.isEnabled = false
        environment.settings.search.isCorpusEnabled = true
        environment.settings.search.isCrossReferencePreparationEnabled = true
        return environment
    }

    /// Serves what the corpus and cross-reference coordinators ask of an engine
    /// with nothing indexed, recording the limits and evictions; an eviction
    /// waits for `heldEvictions` when there is one.
    private static func serveBackgroundWork(on peer: ScriptedPeer, recordingInto requests: RecordedEngineRequests, holdingEvictionsWith heldEvictions: HeldRequests? = nil) {
        peer.serve(.interfaceCorpusCoverage) { RuntimeInterfaceCorpusCoverage.empty }
        peer.serve(.indexedImagePaths) { [String]() }
        peer.serve(.setInterfaceCorpusResidentByteLimit, reading: ByteLimitRequest.self) { request in
            await requests.record(.corpusResidentByteLimit(request.byteLimit))
            return RuntimeEngineEmpty()
        }
        peer.serve(.crossReferenceSetPreparedByteLimit, reading: ByteLimitRequest.self) { request in
            await requests.record(.preparedCrossReferenceByteLimit(request.byteLimit))
            return RuntimeEngineEmpty()
        }
        peer.serve(.evictInterfaceCorpus, reading: EvictionRequest.self) { request in
            await requests.record(.corpusEviction(imagePath: request.imagePath))
            await heldEvictions?.hold()
            return RuntimeEngineEmpty()
        }
    }

    /// The fields of the two byte-limit commands.
    private struct ByteLimitRequest: Codable {
        let byteLimit: Int
    }

    /// The field of the eviction command: `nil` evicts every image.
    private struct EvictionRequest: Codable {
        let imagePath: String?
    }
}

/// What the engine heard, in order, with the test's own markers among it.
private enum EngineRequest: Equatable, Sendable {
    case corpusResidentByteLimit(Int)
    case corpusEviction(imagePath: String?)
    case preparedCrossReferenceByteLimit(Int)
    /// The test let the held eviction go.
    case evictionLetGo

    var isCorpusResidentByteLimit: Bool {
        if case .corpusResidentByteLimit = self { return true }
        return false
    }

    var isPreparedCrossReferenceByteLimit: Bool {
        if case .preparedCrossReferenceByteLimit = self { return true }
        return false
    }
}

private actor RecordedEngineRequests {
    private var requests: [EngineRequest] = []

    func record(_ request: EngineRequest) {
        requests.append(request)
    }

    /// The requests once `condition` holds of them; throws after `timeout`
    /// seconds, saying what was heard.
    func waitUntil(timeout: TimeInterval = 10, _ condition: @Sendable ([EngineRequest]) -> Bool) async throws -> [EngineRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(requests) {
            guard Date() < deadline else { throw RequestsNotHeard(heard: requests) }
            try await Task.sleep(for: .milliseconds(20))
        }
        return requests
    }
}

private struct RequestsNotHeard: Swift.Error, CustomStringConvertible {
    let heard: [EngineRequest]

    var description: String { "the engine never heard what the test waited for; it heard \(heard)" }
}

private extension Sequence where Element: Equatable {
    func count(of element: Element) -> Int {
        count { $0 == element }
    }
}

#endif
