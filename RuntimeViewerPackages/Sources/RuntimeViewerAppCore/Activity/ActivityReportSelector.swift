import Foundation

/// Picks the report an activity display shows, the way Xcode's `ActivityViewReportCoordinator` does
/// (IDEKit 26.6 `nextActivityToReport()` and `updateIfNecessary(with:)`, the same code in 27.2):
///
/// - a run the user asked for is shown at once, the newest first;
/// - otherwise the oldest run nobody waits on that has gone on for `backgroundDisplayDelay`;
/// - otherwise the run that ended last, until another run takes its place;
/// - a report on screen stays at least `minimumDisplayDuration`, unless a run the user asked for
///   comes, or the report on screen ends.
///
/// One per window: what each window shows depends on when it started looking.
package struct ActivityReportSelector {
    /// How long a run nobody waits on goes on before it is shown (`startPreDisplayDelayValidatorForReport:`).
    static let backgroundDisplayDelay: TimeInterval = 4

    /// How long a report stays on screen before another takes its place (`minimumReportTime`).
    static let minimumDisplayDuration: TimeInterval = 3

    package struct Selection: Equatable {
        /// The report to show, as of the latest snapshot; `nil` for none.
        package var report: ActivityReport?

        /// The runs under way, plus the report shown when it is not one of them; 0 while nothing
        /// is shown.
        package var activityCount: Int

        /// When the selection can change without a new snapshot — a run reaching its display
        /// delay, the report on screen reaching its minimum time — so the caller updates again
        /// then.
        package var nextUpdateDate: Date?
    }

    private var displayedReport: ActivityReport?

    private var displayStartDate: Date?

    package init() {}

    package mutating func update(with snapshot: ActivityReportsSnapshot, now: Date) -> Selection {
        let candidate = Self.nextReport(in: snapshot, now: now)
        var nextUpdateDate = Self.nextDisplayDelayEnd(in: snapshot, now: now)

        // The report on screen as the snapshot has it now: still running, ended, or gone.
        let refreshedDisplayedReport = displayedReport.flatMap { displayedReport in
            snapshot.runningReports.first { $0.id == displayedReport.id }
                ?? (snapshot.lastCompletedReport?.id == displayedReport.id ? snapshot.lastCompletedReport : nil)
        }

        if let candidate, candidate.id == displayedReport?.id {
            displayedReport = candidate
        } else {
            let hasMetMinimumDuration = displayStartDate.map { now.timeIntervalSince($0) >= Self.minimumDisplayDuration } ?? true
            let canReplace = displayedReport == nil
                || refreshedDisplayedReport == nil
                || refreshedDisplayedReport?.isCompleted == true
                || candidate?.isUserRequested == true
                || hasMetMinimumDuration
            if canReplace {
                displayedReport = candidate
                displayStartDate = candidate == nil ? nil : now
            } else {
                displayedReport = refreshedDisplayedReport
                if let displayStartDate {
                    nextUpdateDate = Self.earlier(nextUpdateDate, displayStartDate.addingTimeInterval(Self.minimumDisplayDuration))
                }
            }
        }

        let activityCount: Int
        if let displayedReport {
            let isDisplayedReportRunning = snapshot.runningReports.contains { $0.id == displayedReport.id }
            activityCount = snapshot.runningReports.count + (isDisplayedReportRunning ? 0 : 1)
        } else {
            activityCount = 0
        }
        return Selection(report: displayedReport, activityCount: activityCount, nextUpdateDate: nextUpdateDate)
    }

    /// The report Xcode's `nextActivityToReport()` would pick.
    static func nextReport(in snapshot: ActivityReportsSnapshot, now: Date) -> ActivityReport? {
        if let userRequestedReport = snapshot.runningReports.first(where: \.isUserRequested) {
            return userRequestedReport
        }
        // The running reports come newest first, so the last one past its delay is the oldest.
        if let backgroundReport = snapshot.runningReports.last(where: { hasMetDisplayDelay($0, now: now) }) {
            return backgroundReport
        }
        return snapshot.lastCompletedReport
    }

    private static func hasMetDisplayDelay(_ report: ActivityReport, now: Date) -> Bool {
        report.isUserRequested || now.timeIntervalSince(report.startDate) >= backgroundDisplayDelay
    }

    /// The first time from now at which a running report reaches its display delay.
    private static func nextDisplayDelayEnd(in snapshot: ActivityReportsSnapshot, now: Date) -> Date? {
        snapshot.runningReports
            .filter { !hasMetDisplayDelay($0, now: now) }
            .map { $0.startDate.addingTimeInterval(backgroundDisplayDelay) }
            .min()
    }

    private static func earlier(_ first: Date?, _ second: Date) -> Date {
        guard let first else { return second }
        return min(first, second)
    }
}
