import Foundation

/// One run of one kind of an engine's background work — from the moment the kind has work to do
/// until it has none — and how the run ended: what the toolbar's activity display shows, as
/// Xcode's activity view shows an `IDEActivityReport`.
///
/// A kind runs again once it has work again; that run is another report, with another identifier.
/// The reports are worked out once per engine (`RuntimeEngineActivityReporter`), so every window
/// on the engine sees the same ones.
public struct ActivityReport: Hashable, Sendable, Identifiable {
    /// How a run ended.
    public enum Outcome: Hashable, Sendable {
        case succeeded
        /// Some of the run's images failed.
        case failed
        /// The run was cancelled before every image was done.
        case cancelled
    }

    public let id: UUID

    /// The kind of work: the Report navigator's category for it.
    public let kind: ReportCategory

    /// When the run started: a report the user did not ask for is shown only once it has run for
    /// a while (`ActivityReportSelector.backgroundDisplayDelay`).
    public let startDate: Date

    /// The user asked for the work — a Find search waits on it, or a manual indexing — so the
    /// report is shown at once, ahead of the work nobody waits on.
    public var isUserRequested: Bool

    /// Images of the run that are done, whatever the outcome.
    public var finishedCount: Int

    /// Images of the run so far. It grows when work joins the run, so the fraction done can go
    /// down.
    public var totalCount: Int

    /// How far the run is, from 0 to 1, with the images under way counted by their own progress;
    /// `nil` while nothing tells how far it is.
    public var fractionCompleted: Double?

    /// How the run ended, and when; `nil` while it runs.
    public var completion: Completion?

    public struct Completion: Hashable, Sendable {
        public var outcome: Outcome

        public var date: Date

        public init(outcome: Outcome, date: Date) {
            self.outcome = outcome
            self.date = date
        }
    }

    public var isCompleted: Bool {
        completion != nil
    }

    public init(
        id: UUID = UUID(),
        kind: ReportCategory,
        startDate: Date,
        isUserRequested: Bool = false,
        finishedCount: Int = 0,
        totalCount: Int = 0,
        fractionCompleted: Double? = nil,
        completion: Completion? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startDate = startDate
        self.isUserRequested = isUserRequested
        self.finishedCount = finishedCount
        self.totalCount = totalCount
        self.fractionCompleted = fractionCompleted
        self.completion = completion
    }
}

/// An engine's reports at one moment: what the activity display chooses from.
public struct ActivityReportsSnapshot: Hashable, Sendable {
    /// The runs under way, the newest first.
    public var runningReports: [ActivityReport]

    /// The run that ended last, of any kind; `nil` until one has ended.
    public var lastCompletedReport: ActivityReport?

    public init(runningReports: [ActivityReport] = [], lastCompletedReport: ActivityReport? = nil) {
        self.runningReports = runningReports
        self.lastCompletedReport = lastCompletedReport
    }

    public static let empty = ActivityReportsSnapshot()

    /// Several engines' reports at one moment, as one: every run under way, the newest first, and
    /// the run that ended last among them all.
    package static func merged(_ snapshots: [ActivityReportsSnapshot]) -> ActivityReportsSnapshot {
        let runningReports = snapshots.flatMap(\.runningReports).sorted { $0.startDate > $1.startDate }
        let lastCompletedReport = snapshots.compactMap(\.lastCompletedReport).max { leftReport, rightReport in
            (leftReport.completion?.date ?? .distantPast) < (rightReport.completion?.date ?? .distantPast)
        }
        return ActivityReportsSnapshot(runningReports: runningReports, lastCompletedReport: lastCompletedReport)
    }
}
