import Foundation
import RuntimeViewerArchitectures
@testable import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// The activity an engine's background work holds while any of it is in
/// progress (`Documentations/ResolvedIssues/2026-10-13-background-work-throttled-by-app-nap.md`).
///
/// The work runs in the local-runtime XPC service, which runs at full speed
/// only while the app waiting on it donates importance, and an app in App Nap
/// donates none. So the app holds a user-initiated activity — one, however
/// often the work is reported — exactly while work is in progress, and ends
/// that same activity when the work ends, when the engine's work closes as
/// its last document leaves, or when the activity's owner goes away. One
/// activity per engine's work: each document on the engine used to hold one
/// of its own, following the same answer.
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

    @Test("closing ends the activity, and work reported afterwards takes none")
    func closingEndsTheActivity() async throws {
        let scheduler = RecordingProcessActivityScheduler()
        let isWorkInProgress = BehaviorRelay(value: true)
        let processActivity = BackgroundWorkProcessActivity(isWorkInProgress: isWorkInProgress.asDriver(), scheduler: scheduler)
        defer { withExtendedLifetime(processActivity) {} }
        try await settleMainQueue()
        #expect(scheduler.heldActivityCount == 1)

        processActivity.close()

        #expect(scheduler.endedActivityIdentifiers == scheduler.begunActivityIdentifiers, "closing left the activity held")
        isWorkInProgress.accept(false)
        isWorkInProgress.accept(true)
        try await settleMainQueue()
        #expect(scheduler.begunActivityIdentifiers.count == 1, "a closed activity was taken again")
        #expect(!processActivity.isHoldingActivity)
    }

    /// A report reaches the activity a main-actor turn after it is made, so one can still be on
    /// its way when the work closes — work starting in the turn its last document leaves.
    @Test("work reported in the turn the activity closes takes no activity once the report arrives")
    func reportOnItsWayWhenClosingTakesNoActivity() async throws {
        let scheduler = RecordingProcessActivityScheduler()
        let isWorkInProgress = BehaviorRelay(value: false)
        let processActivity = BackgroundWorkProcessActivity(isWorkInProgress: isWorkInProgress.asDriver(), scheduler: scheduler)
        defer { withExtendedLifetime(processActivity) {} }
        try await settleMainQueue()

        isWorkInProgress.accept(true)
        processActivity.close()
        try await settleMainQueue()

        #expect(!processActivity.isHoldingActivity, "the report on its way when the work closed took the activity again")
        #expect(scheduler.heldActivityCount == 0)
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

    /// What the app does: the activity of the engine's work, brought into
    /// being with the coordinators as the document starts its background work,
    /// against a corpus build on a real engine.
    @Test("a corpus build keeps the engine's activity held until every build has ended")
    func corpusBuildHoldsTheActivity() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "BackgroundWorkProcessActivityTests.corpus", loading: [TestImages.libobjc, TestImages.foundation])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let documentState = environment.documentState
        let scheduler = RecordingProcessActivityScheduler()
        environment.backgroundWorkRegistry.processActivityScheduler = scheduler
        environment.startBackgroundWork()
        let processActivity = try #require(environment.backgroundWorkRegistry.backgroundWork(on: engine)?.processActivity)

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

    #if canImport(Network)
    // MARK: - One activity per engine

    /// An image only the scripted engines list; nothing loads it in this process.
    private static let scriptedImagePath = "/Scripted/libActivity.dylib"

    @Test("with two documents on an engine whose work is in progress, the activity stays held until the last of them leaves")
    func activityOutlastsAllButTheLastDocument() async throws {
        let (peer, heldLoads) = try await Self.makePeerHoldingLoads(label: "BackgroundWorkProcessActivityTests.twoDocuments")
        let firstEnvironment = ViewModelTestEnvironment(runtimeEngine: peer.client)
        let secondEnvironment = ViewModelTestEnvironment(runtimeEngine: peer.client)
        Self.enableAlwaysIndex(in: firstEnvironment)
        Self.enableAlwaysIndex(in: secondEnvironment)
        let scheduler = RecordingProcessActivityScheduler()
        firstEnvironment.backgroundWorkRegistry.processActivityScheduler = scheduler
        firstEnvironment.startBackgroundWork()
        secondEnvironment.startBackgroundWork()
        // The batch for the scripted image waits on its load, so the work stays in progress.
        try await waitUntil(timeout: 30) { scheduler.heldActivityCount == 1 }

        firstEnvironment.make { firstEnvironment.documentState.documentWillClose() }
        try await settleMainQueue()

        #expect(scheduler.heldActivityCount == 1, "a document left while another stays on the engine, and the activity went with it")
        #expect(scheduler.begunActivityIdentifiers.count == 1)

        secondEnvironment.make { secondEnvironment.documentState.documentWillClose() }

        #expect(scheduler.heldActivityCount == 0, "the last document left the engine and its activity stayed held")
        await heldLoads.release()
        await peer.stop()
    }

    /// The case the App Nap fix was about, on a document that moved: the
    /// engine it moves to has work in progress, and that work holds the
    /// activity.
    @Test("a document moved to an engine whose work is in progress holds that engine's activity")
    func activityFollowsTheDocumentToAnotherEngine() async throws {
        let idleEngine = try await TestRuntimeEngine.makeConnected(engineID: "BackgroundWorkProcessActivityTests.moved.idle")
        let (peer, heldLoads) = try await Self.makePeerHoldingLoads(label: "BackgroundWorkProcessActivityTests.moved.busy")
        let environment = ViewModelTestEnvironment(runtimeEngine: idleEngine)
        // The idle engine does not list the scripted image, so its work has nothing to do.
        Self.enableAlwaysIndex(in: environment)
        let scheduler = RecordingProcessActivityScheduler()
        let registry = environment.backgroundWorkRegistry
        registry.processActivityScheduler = scheduler
        environment.startBackgroundWork()
        try await settleMainQueue()
        #expect(scheduler.heldActivityCount == 0, "an engine with nothing to do holds an activity")

        environment.make { environment.documentState.selectionRouter.trigger(.switchEngine(peer.client)) }

        try await waitUntil(timeout: 30) { scheduler.heldActivityCount == 1 }
        #expect(registry.backgroundWork(on: peer.client)?.processActivity.isHoldingActivity == true, "the activity held is not the work of the engine the document moved to")
        environment.make { environment.documentState.documentWillClose() }
        #expect(scheduler.heldActivityCount == 0)
        await heldLoads.release()
        await peer.stop()
        await idleEngine.stop()
    }

    /// Turns on Always Index alone, with a row for the scripted image on every engine: heuristic
    /// discovery stays off, so the only batches are the row's.
    private static func enableAlwaysIndex(in environment: ViewModelTestEnvironment) {
        environment.settings.indexing.isEnabled = true
        environment.settings.indexing.heuristic.isEnabled = false
        environment.settings.indexing.custom.isEnabled = true
        environment.settings.indexing.custom.entries = [Settings.Indexing.AlwaysIndexEntry(identifier: (scriptedImagePath as NSString).lastPathComponent)]
    }

    /// A scripted engine listing the scripted image, not indexed, whose every background load
    /// waits for the test to release it: a batch for the image stays under way until then.
    private static func makePeerHoldingLoads(label: String) async throws -> (ScriptedPeer, HeldRequests) {
        let peer = try await ScriptedPeer.make(label: label)
        let heldLoads = HeldRequests()
        peer.serve(.isImageIndexed) { false }
        peer.serve(.loadImageForBackgroundIndexing) { () async -> RuntimeEngineEmpty in
            await heldLoads.hold()
            return RuntimeEngineEmpty()
        }
        try await peer.connection.sendMessage(name: .imageList, request: [scriptedImagePath])
        let deadline = ContinuousClock.now + .seconds(10)
        while await peer.client.imageList != [scriptedImagePath] {
            guard ContinuousClock.now < deadline else { throw AwaitTimeout(seconds: 10) }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (peer, heldLoads)
    }
    #endif
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
