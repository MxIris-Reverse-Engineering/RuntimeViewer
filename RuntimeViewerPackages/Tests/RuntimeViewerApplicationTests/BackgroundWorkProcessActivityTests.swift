import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// The activity a document holds while it has background work in progress
/// (`Documentations/ResolvedIssues/2026-10-13-background-work-throttled-by-app-nap.md`).
///
/// The work runs in the local-runtime XPC service, which runs at full speed
/// only while the app waiting on it donates importance, and an app in App Nap
/// donates none. So the app holds a user-initiated activity — one, however
/// often the work is reported — exactly while work is in progress, and ends
/// that same activity when the work ends, when the document closes, or when
/// the activity's owner goes away.
@Suite("Background work process activity", .serialized)
@MainActor
struct BackgroundWorkProcessActivityTests {
    @Test("holds one user-initiated activity while work is in progress, and ends it when the work ends")
    func followsWorkInProgress() async throws {
        let scheduler = RecordingProcessActivityScheduler()
        let isWorkInProgress = BehaviorRelay(value: false)
        let processActivity = BackgroundWorkProcessActivity(isWorkInProgress: isWorkInProgress.asDriver(), scheduler: scheduler)
        defer { withExtendedLifetime(processActivity) {} }
        try await settleMainQueue()
        #expect(scheduler.begunActivityIdentifiers.isEmpty, "an activity was taken with no work in progress")

        isWorkInProgress.accept(true)
        try await settleMainQueue()
        #expect(scheduler.begunActivityIdentifiers.count == 1)
        #expect(scheduler.begunOptions == [.userInitiatedAllowingIdleSystemSleep])
        #expect(processActivity.isHoldingActivity)

        // The same state reported again takes no second activity.
        isWorkInProgress.accept(true)
        try await settleMainQueue()
        #expect(scheduler.begunActivityIdentifiers.count == 1, "a repeated report took a second activity")

        isWorkInProgress.accept(false)
        try await settleMainQueue()
        #expect(scheduler.endedActivityIdentifiers == scheduler.begunActivityIdentifiers, "the work ended and the activity it took was not ended")
        #expect(!processActivity.isHoldingActivity)

        isWorkInProgress.accept(true)
        try await settleMainQueue()
        #expect(scheduler.begunActivityIdentifiers.count == 2)
        #expect(scheduler.heldActivityCount == 1)
    }

    @Test("closing the document ends the activity, and work reported afterwards takes none")
    func closingEndsTheActivity() async throws {
        let scheduler = RecordingProcessActivityScheduler()
        let isWorkInProgress = BehaviorRelay(value: true)
        let processActivity = BackgroundWorkProcessActivity(isWorkInProgress: isWorkInProgress.asDriver(), scheduler: scheduler)
        defer { withExtendedLifetime(processActivity) {} }
        try await settleMainQueue()
        #expect(scheduler.heldActivityCount == 1)

        processActivity.documentWillClose()

        #expect(scheduler.endedActivityIdentifiers == scheduler.begunActivityIdentifiers, "closing the document left the activity held")
        isWorkInProgress.accept(false)
        isWorkInProgress.accept(true)
        try await settleMainQueue()
        #expect(scheduler.begunActivityIdentifiers.count == 1, "a closed document took an activity again")
        #expect(!processActivity.isHoldingActivity)
    }

    @Test("an activity still held when its owner goes away is ended with it")
    func releasingTheOwnerEndsTheActivity() async throws {
        let scheduler = RecordingProcessActivityScheduler()
        let isWorkInProgress = BehaviorRelay(value: true)
        var processActivity: BackgroundWorkProcessActivity? = BackgroundWorkProcessActivity(isWorkInProgress: isWorkInProgress.asDriver(), scheduler: scheduler)
        weak var releasedProcessActivity = processActivity
        try await settleMainQueue()
        #expect(scheduler.heldActivityCount == 1)

        processActivity = nil

        #expect(releasedProcessActivity == nil, "something else kept the activity's owner alive")
        #expect(scheduler.heldActivityCount == 0, "the owner went away and its activity stayed held")
    }

    /// What the app does: the document's own activity, brought into being
    /// with the coordinators, against a corpus build on a real engine.
    @Test("a corpus build keeps the document's activity held until every build has ended")
    func corpusBuildHoldsTheActivity() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "BackgroundWorkProcessActivityTests.corpus", loading: [TestImages.libobjc, TestImages.foundation])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let documentState = environment.documentState
        let scheduler = RecordingProcessActivityScheduler()
        documentState.processActivityScheduler = scheduler
        // As `Document.makeWindowControllers` starts it: the coordinators and the activity.
        environment.startBackgroundWork()
        let indexingCoordinator = try documentState.joinedIndexingCoordinator()
        let corpusCoordinator = try documentState.joinedCorpusCoordinator()
        let processActivity = documentState.backgroundWorkProcessActivity
        defer { withExtendedLifetime((indexingCoordinator, corpusCoordinator, processActivity)) {} }

        // Foundation takes seconds to print, so the work is still under way
        // when this resumes.
        _ = try await nextValue(from: documentState.reportActivity, timeout: 60) { $0 }
        #expect(processActivity.isHoldingActivity, "a corpus build is under way and the app holds no activity")

        _ = try await nextValue(from: documentState.reportActivity, timeout: 120) { !$0 }
        try await settleMainQueue()
        #expect(!processActivity.isHoldingActivity, "every build has ended and the activity is still held")
        #expect(scheduler.heldActivityCount == 0)
        #expect(!scheduler.begunActivityIdentifiers.isEmpty)
        #expect(scheduler.begunOptions.allSatisfy { $0 == .userInitiatedAllowingIdleSystemSleep })

        environment.make { documentState.documentWillClose() }
        await engine.stop()
    }
}

/// Records what `BackgroundWorkProcessActivity` asks of `ProcessInfo`, holding
/// no real activity.
final class RecordingProcessActivityScheduler: ProcessActivityScheduling {
    private(set) var begunActivityIdentifiers: [ObjectIdentifier] = []

    private(set) var begunOptions: [ProcessInfo.ActivityOptions] = []

    private(set) var endedActivityIdentifiers: [ObjectIdentifier] = []

    /// Keeps every activity handed out alive, so no identifier is reused.
    private var activities: [NSObject] = []

    var heldActivityCount: Int {
        begunActivityIdentifiers.count - endedActivityIdentifiers.count
    }

    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol {
        let activity = NSObject()
        activities.append(activity)
        begunActivityIdentifiers.append(ObjectIdentifier(activity))
        begunOptions.append(options)
        return activity
    }

    func endActivity(_ activity: any NSObjectProtocol) {
        endedActivityIdentifiers.append(ObjectIdentifier(activity))
    }
}
