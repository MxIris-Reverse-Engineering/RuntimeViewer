import Foundation
@testable import RuntimeViewerCore
import RuntimeViewerCrossReferences
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// The cross-reference preparation coordinator against a private engine: the
/// indexed images get prepared, an image indexed later too, the switch going
/// off withdraws everything, and a withdrawn request goes to the history as
/// cancelled.
@Suite("CrossReferencePreparationCoordinator", .serialized)
@MainActor
struct CrossReferencePreparationCoordinatorTests {
    private func makeCoordinator(on engine: RuntimeEngine, in environment: ViewModelTestEnvironment) -> CrossReferencePreparationCoordinator {
        environment.settings.search.isCrossReferencePreparationEnabled = true
        return environment.make { CrossReferencePreparationCoordinator(engine: environment.documentState.runtimeEngine) }
    }

    private static func isPrepared(_ state: CrossReferencePreparationState?) -> Bool {
        state?.isPrepared == true
    }

    @Test("every image the engine has indexed is prepared, and listed as prepared")
    func indexedImagesArePrepared() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "CrossReferencePreparationCoordinatorTests.indexed", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let coordinator = makeCoordinator(on: engine, in: environment)
        defer { withExtendedLifetime(coordinator) {} }

        let states = try await nextValue(from: coordinator.$preparationStatesByImagePath.asDriver(), timeout: 60) { Self.isPrepared($0[TestImages.libobjc]) }
        guard case .prepared(let preparation)? = states[TestImages.libobjc] else {
            Issue.record("libobjc is not prepared: \(states)")
            return
        }
        #expect(preparation.referenceCount > 0)
        #expect(coordinator.finishedPreparations.contains { finishedPreparation in
            if case .prepared = finishedPreparation.outcome { return finishedPreparation.imagePath == TestImages.libobjc }
            return false
        })
        await engine.stop()
    }

    @Test("an image the engine indexes later is prepared once it is indexed")
    func imagesIndexedLaterArePrepared() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "CrossReferencePreparationCoordinatorTests.later")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let coordinator = makeCoordinator(on: engine, in: environment)
        defer { withExtendedLifetime(coordinator) {} }
        #expect(!Self.isPrepared(coordinator.preparationStatesByImagePath[TestImages.libobjc]))

        try await engine.loadImage(at: TestImages.libobjc)

        let states = try await nextValue(from: coordinator.$preparationStatesByImagePath.asDriver(), timeout: 60) { Self.isPrepared($0[TestImages.libobjc]) }
        #expect(Self.isPrepared(states[TestImages.libobjc]))
        await engine.stop()
    }

    @Test("turning Keep Cross References Ready off withdraws every request; turning it on prepares the indexed images again")
    func switchingOffWithdrawsAndOnPreparesAgain() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "CrossReferencePreparationCoordinatorTests.switch", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let coordinator = makeCoordinator(on: engine, in: environment)
        defer { withExtendedLifetime(coordinator) {} }
        _ = try await nextValue(from: coordinator.$preparationStatesByImagePath.asDriver(), timeout: 60) { Self.isPrepared($0[TestImages.libobjc]) }

        environment.settings.search.isCrossReferencePreparationEnabled = false
        let dropped = try await nextValue(from: coordinator.$preparationStatesByImagePath.asDriver()) { $0.isEmpty }
        #expect(dropped.isEmpty)
        #expect(coordinator.followedImagePaths.isEmpty)

        environment.settings.search.isCrossReferencePreparationEnabled = true
        let preparedAgain = try await nextValue(from: coordinator.$preparationStatesByImagePath.asDriver(), timeout: 60) { Self.isPrepared($0[TestImages.libobjc]) }
        #expect(Self.isPrepared(preparedAgain[TestImages.libobjc]))
        await engine.stop()
    }

    @Test("a request withdrawn from the Report goes to the history as cancelled, and asks for nothing more")
    func cancellingRecordsTheRequestAsCancelled() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "CrossReferencePreparationCoordinatorTests.cancel")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let coordinator = makeCoordinator(on: engine, in: environment)
        defer { withExtendedLifetime(coordinator) {} }
        try await engine.loadImage(at: TestImages.foundation)
        // Asked for here rather than left to the engine's notice, so it can be withdrawn at once.
        coordinator.requestPreparation(of: TestImages.foundation)
        #expect(coordinator.followedImagePaths.contains(TestImages.foundation))

        coordinator.cancelPreparation(of: TestImages.foundation)

        #expect(coordinator.preparationStatesByImagePath[TestImages.foundation] == nil)
        #expect(!coordinator.followedImagePaths.contains(TestImages.foundation))
        #expect(coordinator.finishedPreparations.first?.imagePath == TestImages.foundation)
        #expect(coordinator.finishedPreparations.first?.outcome == .cancelled)
        await engine.stop()
    }

    @Test("off, the coordinator asks the engine for nothing")
    func offAsksForNothing() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "CrossReferencePreparationCoordinatorTests.off", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let coordinator = environment.make { CrossReferencePreparationCoordinator(engine: environment.documentState.runtimeEngine) }
        defer { withExtendedLifetime(coordinator) {} }

        coordinator.requestPreparation(of: TestImages.libobjc)

        #expect(try await values(from: coordinator.$preparationStatesByImagePath.asDriver(), during: 0.5).allSatisfy(\.isEmpty))
        #expect(!coordinator.hasWorkUnderWay)
        await engine.stop()
    }
}
