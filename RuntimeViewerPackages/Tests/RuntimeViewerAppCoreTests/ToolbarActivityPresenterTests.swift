import Foundation
import Testing
import RuntimeViewerArchitectures
@testable import RuntimeViewerAppCore

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
        var activities: [ToolbarActivity] = []
        let subscription = ToolbarActivityPresenter.activities(from: snapshots, sourceName: "My Mac", readyDate: Self.start, scheduler: scheduler, now: { scheduler.now })
            .subscribeOnNext { activities.append($0) }
        defer { subscription.dispose() }

        scheduler.advanceTo(Self.start + 3.9)
        let activityBeforeDelay = try #require(activities.last)
        #expect(activityBeforeDelay.reportIdentifier == nil)

        scheduler.advanceTo(Self.start + 4.1)
        let activityAfterDelay = try #require(activities.last)
        #expect(activityAfterDelay.reportIdentifier == report.id)
        #expect(activityAfterDelay.progress == .determinate(percent: 50))
    }

    @Test("A run the user asked for shows with the snapshot that brings it")
    func userRequestedRunShowsWithItsSnapshot() throws {
        let scheduler = HistoricalScheduler(initialClock: Self.start)
        let snapshots = BehaviorSubject(value: ActivityReportsSnapshot.empty)
        var activities: [ToolbarActivity] = []
        let subscription = ToolbarActivityPresenter.activities(from: snapshots, sourceName: "My Mac", readyDate: Self.start, scheduler: scheduler, now: { scheduler.now })
            .subscribeOnNext { activities.append($0) }
        defer { subscription.dispose() }
        let report = ActivityReport(kind: .searchableInterfaces, startDate: Self.start, isUserRequested: true, totalCount: 1, fractionCompleted: 0)

        snapshots.onNext(ActivityReportsSnapshot(runningReports: [report]))

        let activity = try #require(activities.last)
        #expect(activity.reportIdentifier == report.id)
    }

    @Test("A re-selection that changes nothing on screen is no new activity, so it takes no throttle window")
    func toolbarActivityThrottlesOnDisplayedValue() throws {
        let report = ActivityReport(kind: .backgroundIndexing, startDate: Self.start, finishedCount: 1, totalCount: 2, fractionCompleted: 0.5)
        let firstSelection = ActivityReportSelector.Selection(report: report, activityCount: 1, nextUpdateDate: Self.start + 3)
        let reselection = ActivityReportSelector.Selection(report: report, activityCount: 1, nextUpdateDate: nil)

        let firstActivity = ToolbarActivity.make(for: firstSelection, sourceName: "My Mac", readyDate: Self.start)
        let reselectedActivity = ToolbarActivity.make(for: reselection, sourceName: "My Mac", readyDate: Self.start)

        #expect(firstActivity == reselectedActivity)
    }
}
