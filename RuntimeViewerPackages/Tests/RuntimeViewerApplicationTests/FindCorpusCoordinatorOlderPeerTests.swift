#if canImport(Network)

import Foundation
import RuntimeViewerCommunication
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// The corpus coordinator against a peer older than the corpus commands — a
/// device or a Mac still on a release before the Find navigator, or a mirror
/// relayed through one. Since 2.1.0 such a peer answers a command it does not
/// know with "No handler registered for …", and every image used to be
/// recorded as a failed build saying exactly that (PR121.37).
@Suite("FindCorpusCoordinator against an older peer", .serialized)
@MainActor
struct FindCorpusCoordinatorOlderPeerTests {
    @Test("a peer that predates the corpus commands records no failed build")
    func peerWithoutCorpusCommandsRecordsNoFailure() async throws {
        // A connection that serves no command at all: what a peer older than
        // the Find navigator is, as far as corpus commands go.
        let olderPeer = try await RuntimeCommunicator().connect(
            to: .directTCP(name: "FindCorpusCoordinatorOlderPeerTests.peer", host: nil, port: 0, role: .server),
            waitForConnection: false
        )
        defer { olderPeer.stop() }
        let port = try #require(olderPeer.connectionInfo?.port)
        let engine = RuntimeEngine(
            source: .directTCP(name: "FindCorpusCoordinatorOlderPeerTests.client", host: "127.0.0.1", port: port, role: .client),
            engineID: "FindCorpusCoordinatorOlderPeerTests.client"
        )
        try await engine.connect()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }

        coordinator.requestBuild(of: TestImages.libobjc)
        coordinator.requestBuild(of: TestImages.foundation)

        let states = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 10) { states in
            states.values.allSatisfy { !$0.isActive }
        }
        let failedBuilds = coordinator.finishedBuilds.filter { finishedBuild in
            if case .failed = finishedBuild.outcome { return true }
            return false
        }
        #expect(failedBuilds.isEmpty, "a peer without corpus commands was recorded as \(failedBuilds.count) failed builds: \(failedBuilds.map(\.outcome))")
        #expect(states.isEmpty, "a peer without corpus commands left states behind: \(states)")
        #expect(coordinator.isCorpusUnsupportedByEngine)

        // Nothing more is asked of that engine…
        coordinator.requestBuild(of: TestImages.libobjc)
        #expect(coordinator.buildStatesByImagePath.isEmpty, "a request went out to a peer known not to serve it")

        // …and another engine starts over.
        let otherEngine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorOlderPeerTests.other")
        environment.documentState.selectionRouter.trigger(.switchEngine(otherEngine))
        #expect(coordinator.isCorpusUnsupportedByEngine == false)
        await engine.stop()
        await otherEngine.stop()
    }
}

#endif
