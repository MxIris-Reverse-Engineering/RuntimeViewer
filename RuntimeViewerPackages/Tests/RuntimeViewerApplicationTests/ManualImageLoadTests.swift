import Foundation
import Testing
@testable import RuntimeViewerCore
@testable import RuntimeViewerAppCore

/// The images the user loads, as the Report navigator's Manual Loading lists them (proposal
/// `editor-jump-bar`): a row while the load runs, an entry with its outcome once it ends, and only
/// for loads that do something.
@Suite("Manual loading")
@MainActor
struct ManualImageLoadTests {
    private static let imagePath = "/System/Library/Frameworks/Sample.framework/Sample"

    private static let progress = RuntimeObjectsLoadingProgress(phase: .loadingObjCClasses, itemDescription: "", currentCount: 1, totalCount: 4)

    // MARK: - The coordinator

    @Test("a load is a row with its progress while it runs, then an entry saying it loaded")
    func loadIsRecorded() async throws {
        let coordinator = ManualImageLoadCoordinator()

        let result = try await coordinator.record(loadOfImageAt: Self.imagePath) { reportProgress in
            await reportProgress(Self.progress)
            let activeLoad = await MainActor.run { coordinator.activeLoadsByImagePath[Self.imagePath] }
            #expect(activeLoad?.phaseDescription == Self.progress.phase.displayDescription)
            #expect(activeLoad?.fractionCompleted == Self.progress.overallFraction)
            return 42
        }

        #expect(result == 42)
        #expect(coordinator.activeLoadsByImagePath.isEmpty)
        #expect(coordinator.finishedLoads.map(\.imagePath) == [Self.imagePath])
        #expect(coordinator.finishedLoads.first?.outcome == .loaded)
    }

    @Test("a load that fails ends as an entry with the reason, and the error reaches the caller")
    func failedLoadIsRecorded() async throws {
        let coordinator = ManualImageLoadCoordinator()

        await #expect(throws: ScriptedLoadFailure.self) {
            try await coordinator.record(loadOfImageAt: Self.imagePath) { _ in
                throw ScriptedLoadFailure()
            }
        }

        guard case .failed? = coordinator.finishedLoads.first?.outcome else {
            Issue.record("the load did not end as a failure: \(coordinator.finishedLoads)")
            return
        }
        #expect(coordinator.activeLoadsByImagePath.isEmpty)
    }

    @Test("two loads of one image at once are one row, and one entry once the last ends")
    func overlappingLoadsOfOneImage() async throws {
        let coordinator = ManualImageLoadCoordinator()

        try await coordinator.record(loadOfImageAt: Self.imagePath) { _ in
            try await coordinator.record(loadOfImageAt: Self.imagePath) { _ in
                let activeCount = await MainActor.run { coordinator.activeLoadsByImagePath.count }
                #expect(activeCount == 1)
            }
            let finishedCount = await MainActor.run { coordinator.finishedLoads.count }
            #expect(finishedCount == 0, "the image still loads for the first caller")
        }

        #expect(coordinator.finishedLoads.count == 1)
    }

    @Test("Clear History empties the entries; the history keeps the newest loads only")
    func historyClearsAndIsBounded() async throws {
        let coordinator = ManualImageLoadCoordinator()
        for index in 0...ManualImageLoadCoordinator.historyLimit {
            try await coordinator.record(loadOfImageAt: "/Images/Image\(index)") { _ in }
        }

        #expect(coordinator.finishedLoads.count == ManualImageLoadCoordinator.historyLimit)
        #expect(coordinator.finishedLoads.first?.imagePath == "/Images/Image\(ManualImageLoadCoordinator.historyLimit)")

        coordinator.clearFinishedLoads()
        #expect(coordinator.finishedLoads.isEmpty)
    }

    @Test("once the last document left the engine, loads run on but are not recorded")
    func closedCoordinatorRecordsNothing() async throws {
        let coordinator = ManualImageLoadCoordinator()
        coordinator.close()

        let result = try await coordinator.record(loadOfImageAt: Self.imagePath) { _ in "loaded" }

        #expect(result == "loaded")
        #expect(coordinator.finishedLoads.isEmpty)
        #expect(coordinator.activeLoadsByImagePath.isEmpty)
    }

    // MARK: - The Report

    @Test("the Report lists the loads running first, then the ones that ended, under Manual Loading")
    func reportCategory() {
        let treeBuilder = ReportTreeBuilder()
        let runningLoad = ManualImageLoad(imagePath: "/Images/Running", startedAt: Date())
        let finishedLoad = FinishedManualImageLoad(id: UUID(), imagePath: "/Images/Done", startedAt: Date(timeIntervalSinceNow: -3), finishedAt: Date(), outcome: .loaded)

        let category = treeBuilder.manualLoadingCategory(activeLoads: [runningLoad.imagePath: runningLoad], finishedLoads: [finishedLoad])

        #expect(category?.cellViewModel.appearance.title == "Manual Loading")
        #expect(category?.children.map(\.identifier) == [.manualLoad(imagePath: "/Images/Running"), .finishedManualLoad(finishedLoad.id)])
        #expect(category?.children.first?.cellViewModel.isInProgress == true)
        #expect(category?.children.last?.cellViewModel.appearance.title == "Done")
        #expect(treeBuilder.manualLoadingCategory(activeLoads: [:], finishedLoads: []) == nil)
    }

    // MARK: - Recording through the document

    @Test("indexing an image for the user is recorded under the document's engine, once: indexed, it records nothing")
    func indexingForTheUserIsRecorded() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ManualImageLoadTests.indexingForTheUser")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        // Background indexing would index libobjc on its own and leave the user nothing to do.
        environment.settings.indexing.isEnabled = false
        environment.startBackgroundWork()
        let coordinator = try environment.documentState.joinedManualImageLoadCoordinator()
        #expect(try await engine.isImageIndexed(path: TestImages.libobjc) == false)

        try await environment.documentState.indexImageForUser(at: TestImages.libobjc)
        #expect(coordinator.finishedLoads.map(\.imagePath) == [TestImages.libobjc])
        #expect(coordinator.finishedLoads.first?.outcome == .loaded)

        try await environment.documentState.indexImageForUser(at: TestImages.libobjc)
        #expect(coordinator.finishedLoads.count == 1)
    }
}

/// What a scripted load throws to fail.
private struct ScriptedLoadFailure: Error {}
