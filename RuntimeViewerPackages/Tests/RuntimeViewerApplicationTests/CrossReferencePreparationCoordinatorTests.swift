import Foundation
@testable import RuntimeViewerCore
import RuntimeViewerCrossReferences
import Testing
@testable import RuntimeViewerAppCore
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

    /// The image's latest preparation that ended at `date` or later: kept, or read and not kept.
    /// Either is the coordinator asking and the engine preparing. Which one it is depends on the
    /// room left in the one session of this process, which the suites running at the same time
    /// prepare their own images in: the coordinator's preparations evict nothing for an image
    /// (proposal `on-demand-corpora-and-cross-references`).
    private static func preparation(of imagePath: String, in coordinator: CrossReferencePreparationCoordinator, since date: Date = .distantPast) -> RuntimeCrossReferencePreparation? {
        guard let finishedPreparation = coordinator.finishedPreparations.first(where: { $0.imagePath == imagePath }), finishedPreparation.finishedAt >= date else { return nil }
        switch finishedPreparation.outcome {
        case .prepared(let preparation), .notKept(let preparation):
            return preparation
        case .failed, .cancelled:
            return nil
        }
    }

    @Test("every image the engine has indexed is prepared, and listed as prepared")
    func indexedImagesArePrepared() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "CrossReferencePreparationCoordinatorTests.indexed", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let coordinator = makeCoordinator(on: engine, in: environment)
        defer { withExtendedLifetime(coordinator) {} }

        try await waitUntil(timeout: 60) { Self.preparation(of: TestImages.libobjc, in: coordinator) != nil }
        let preparation = try #require(Self.preparation(of: TestImages.libobjc, in: coordinator))
        #expect(preparation.referenceCount > 0)
        #expect(Self.isPrepared(coordinator.preparationStatesByImagePath[TestImages.libobjc]) == preparation.isKept)
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

        try await waitUntil(timeout: 60) { Self.preparation(of: TestImages.libobjc, in: coordinator) != nil }
        await engine.stop()
    }

    @Test("turning Keep Cross References Ready off withdraws every request; turning it on prepares the indexed images again")
    func switchingOffWithdrawsAndOnPreparesAgain() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "CrossReferencePreparationCoordinatorTests.switch", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let coordinator = makeCoordinator(on: engine, in: environment)
        defer { withExtendedLifetime(coordinator) {} }
        try await waitUntil(timeout: 60) { Self.preparation(of: TestImages.libobjc, in: coordinator) != nil }

        environment.settings.search.isCrossReferencePreparationEnabled = false
        // The coordinator hears of the change on the main actor, later. Without waiting for it, a
        // first round that ended not kept — its states already empty — lets the switch go back on
        // before the coordinator heard it go off, the two changes reach it as one, and it sees the
        // switch on as it was.
        try await settleMainQueue()
        let dropped = try await nextValue(from: coordinator.$preparationStatesByImagePath.asDriver()) { $0.isEmpty }
        #expect(dropped.isEmpty)
        #expect(coordinator.followedImagePaths.isEmpty)

        let turnedOnAt = Date()
        environment.settings.search.isCrossReferencePreparationEnabled = true
        try await waitUntil(timeout: 60) { Self.preparation(of: TestImages.libobjc, in: coordinator, since: turnedOnAt) != nil }
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
