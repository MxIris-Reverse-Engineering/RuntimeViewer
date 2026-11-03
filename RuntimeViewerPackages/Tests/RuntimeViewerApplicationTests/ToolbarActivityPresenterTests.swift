import Foundation
import Testing
import RuntimeViewerArchitectures
@testable import RuntimeViewerApplication
import RuntimeViewerUI

/// The window's activity display over time: the selection changes on its own when a run reaches
/// its display delay, without a new snapshot of the engine's reports. Runs on a virtual clock.
@Suite("Toolbar activity presenter")
@MainActor
struct ToolbarActivityPresenterTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 1000)

    @Test("A run nobody waits on shows once it has gone on for four seconds, with no new snapshot")
    func backgroundRunShowsAfterItsDelayOnItsOwn() throws {
        let scheduler = HistoricalScheduler(initialClock: Self.start)
        let report = ActivityReport(kind: .backgroundIndexing, startDate: Self.start, finishedCount: 0, totalCount: 2, fractionCompleted: 0.5)
        let snapshots = BehaviorSubject(value: ActivityReportsSnapshot(runningReports: [report]))
        var states: [ToolbarActivityState] = []
        let subscription = ToolbarActivityPresenter.states(from: snapshots, sourceName: "My Mac", readyDate: Self.start, scheduler: scheduler, now: { scheduler.now })
            .subscribeOnNext { states.append($0) }
        defer { subscription.dispose() }

        scheduler.advanceTo(Self.start + 3.9)
        let stateBeforeDelay = try #require(states.last)
        #expect(stateBeforeDelay.reportIdentifier == nil)

        scheduler.advanceTo(Self.start + 4.1)
        let stateAfterDelay = try #require(states.last)
        #expect(stateAfterDelay.reportIdentifier == report.id)
        #expect(stateAfterDelay.progress == .determinate(percent: 50))
    }

    @Test("A run the user asked for shows with the snapshot that brings it")
    func userRequestedRunShowsWithItsSnapshot() throws {
        let scheduler = HistoricalScheduler(initialClock: Self.start)
        let snapshots = BehaviorSubject(value: ActivityReportsSnapshot.empty)
        var states: [ToolbarActivityState] = []
        let subscription = ToolbarActivityPresenter.states(from: snapshots, sourceName: "My Mac", readyDate: Self.start, scheduler: scheduler, now: { scheduler.now })
            .subscribeOnNext { states.append($0) }
        defer { subscription.dispose() }
        let report = ActivityReport(kind: .searchableInterfaces, startDate: Self.start, isUserRequested: true, totalCount: 1, fractionCompleted: 0)

        snapshots.onNext(ActivityReportsSnapshot(runningReports: [report]))

        let state = try #require(states.last)
        #expect(state.reportIdentifier == report.id)
    }
}
