import Foundation
import Testing
@testable import RuntimeViewerAppCore

/// Which report a window's activity display shows, and when it changes — the rules of Xcode's
/// `ActivityViewReportCoordinator` (IDEKit 26.6 and 27.2): a run the user asked for at once, a run
/// nobody waits on after four seconds, the last outcome otherwise, and a report on screen for at
/// least three seconds.
@Suite("Activity report selector")
struct ActivityReportSelectorTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 1000)

    private static func runningReport(_ kind: ReportCategory, startedAt startDate: Date, isUserRequested: Bool = false) -> ActivityReport {
        ActivityReport(kind: kind, startDate: startDate, isUserRequested: isUserRequested, finishedCount: 1, totalCount: 4, fractionCompleted: 0.25)
    }

    private static func completed(_ report: ActivityReport, at date: Date, outcome: ActivityReport.Outcome = .succeeded) -> ActivityReport {
        var report = report
        report.completion = ActivityReport.Completion(outcome: outcome, date: date)
        return report
    }

    @Test("Nothing to show while nothing has run")
    func nothingWhileNothingRan() {
        var selector = ActivityReportSelector()

        let selection = selector.update(with: .empty, now: Self.start)

        #expect(selection.report == nil)
        #expect(selection.activityCount == 0)
        #expect(selection.nextUpdateDate == nil)
    }

    @Test("A run the user asked for shows at once")
    func userRequestedRunShowsAtOnce() {
        var selector = ActivityReportSelector()
        let report = Self.runningReport(.searchableInterfaces, startedAt: Self.start, isUserRequested: true)

        let selection = selector.update(with: ActivityReportsSnapshot(runningReports: [report]), now: Self.start)

        #expect(selection.report?.id == report.id)
    }

    @Test("A run nobody waits on shows only once it has gone on for four seconds")
    func backgroundRunWaitsForItsDisplayDelay() {
        var selector = ActivityReportSelector()
        let report = Self.runningReport(.backgroundIndexing, startedAt: Self.start)
        let snapshot = ActivityReportsSnapshot(runningReports: [report])

        let early = selector.update(with: snapshot, now: Self.start + 3.9)
        #expect(early.report == nil)
        #expect(early.nextUpdateDate == Self.start + 4)

        let late = selector.update(with: snapshot, now: Self.start + 4)
        #expect(late.report?.id == report.id)
        #expect(late.nextUpdateDate == nil)
    }

    @Test("Until a run shows, the run that ended last does")
    func lastCompletedReportShowsWhileRunsWait() {
        var selector = ActivityReportSelector()
        let finishedReport = Self.completed(Self.runningReport(.crossReferences, startedAt: Self.start), at: Self.start + 2)
        let waitingReport = Self.runningReport(.backgroundIndexing, startedAt: Self.start + 3)

        let selection = selector.update(
            with: ActivityReportsSnapshot(runningReports: [waitingReport], lastCompletedReport: finishedReport),
            now: Self.start + 4
        )

        #expect(selection.report?.id == finishedReport.id)
        #expect(selection.report?.isCompleted == true)
    }

    @Test("Of the runs nobody waits on, the oldest one shows")
    func oldestBackgroundRunShows() {
        var selector = ActivityReportSelector()
        let olderReport = Self.runningReport(.backgroundIndexing, startedAt: Self.start)
        let newerReport = Self.runningReport(.crossReferences, startedAt: Self.start + 1)

        let selection = selector.update(with: ActivityReportsSnapshot(runningReports: [newerReport, olderReport]), now: Self.start + 10)

        #expect(selection.report?.id == olderReport.id)
    }

    @Test("A run the user asked for takes the place of the report on screen at once")
    func userRequestedRunReplacesAtOnce() {
        var selector = ActivityReportSelector()
        let backgroundReport = Self.runningReport(.backgroundIndexing, startedAt: Self.start)
        _ = selector.update(with: ActivityReportsSnapshot(runningReports: [backgroundReport]), now: Self.start + 4)
        let userRequestedReport = Self.runningReport(.searchableInterfaces, startedAt: Self.start + 5, isUserRequested: true)

        let selection = selector.update(
            with: ActivityReportsSnapshot(runningReports: [userRequestedReport, backgroundReport]),
            now: Self.start + 5
        )

        #expect(selection.report?.id == userRequestedReport.id)
    }

    @Test("A run on screen keeps its place for three seconds against a run nobody waits on")
    func runOnScreenStaysForItsMinimumDuration() {
        var selector = ActivityReportSelector()
        let shownReport = Self.runningReport(.crossReferences, startedAt: Self.start)
        _ = selector.update(with: ActivityReportsSnapshot(runningReports: [shownReport]), now: Self.start + 4)
        // An older run comes to light — its kind's work was read late — and takes the lead.
        let olderReport = Self.runningReport(.backgroundIndexing, startedAt: Self.start - 1)
        let snapshot = ActivityReportsSnapshot(runningReports: [shownReport, olderReport])

        let blocked = selector.update(with: snapshot, now: Self.start + 6)
        #expect(blocked.report?.id == shownReport.id)
        #expect(blocked.nextUpdateDate == Self.start + 7)

        let replaced = selector.update(with: snapshot, now: Self.start + 7)
        #expect(replaced.report?.id == olderReport.id)
    }

    @Test("The report on screen ending lets the next run in at once")
    func endingReportLetsTheNextOneIn() {
        var selector = ActivityReportSelector()
        let firstReport = Self.runningReport(.searchableInterfaces, startedAt: Self.start, isUserRequested: true)
        let secondReport = Self.runningReport(.backgroundIndexing, startedAt: Self.start - 10)
        _ = selector.update(with: ActivityReportsSnapshot(runningReports: [firstReport, secondReport]), now: Self.start)

        let selection = selector.update(
            with: ActivityReportsSnapshot(runningReports: [secondReport], lastCompletedReport: Self.completed(firstReport, at: Self.start + 1)),
            now: Self.start + 1
        )

        #expect(selection.report?.id == secondReport.id)
    }

    @Test("The report on screen ending shows its outcome until another run is due")
    func endingReportShowsItsOutcome() {
        var selector = ActivityReportSelector()
        let report = Self.runningReport(.searchableInterfaces, startedAt: Self.start, isUserRequested: true)
        _ = selector.update(with: ActivityReportsSnapshot(runningReports: [report]), now: Self.start)

        let selection = selector.update(
            with: ActivityReportsSnapshot(lastCompletedReport: Self.completed(report, at: Self.start + 1, outcome: .failed)),
            now: Self.start + 1
        )

        #expect(selection.report?.id == report.id)
        #expect(selection.report?.completion?.outcome == .failed)
    }

    @Test("The count is the runs under way, plus the report on screen when it is not one of them")
    func activityCountIncludesTheReportOnScreen() {
        var selector = ActivityReportSelector()
        let finishedReport = Self.completed(Self.runningReport(.crossReferences, startedAt: Self.start), at: Self.start + 1)
        let waitingReport = Self.runningReport(.backgroundIndexing, startedAt: Self.start + 2)

        let selection = selector.update(
            with: ActivityReportsSnapshot(runningReports: [waitingReport], lastCompletedReport: finishedReport),
            now: Self.start + 3
        )

        #expect(selection.report?.id == finishedReport.id)
        #expect(selection.activityCount == 2)
    }
}
