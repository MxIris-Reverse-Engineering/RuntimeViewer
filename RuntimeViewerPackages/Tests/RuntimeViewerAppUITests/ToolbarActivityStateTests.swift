import Foundation
import Testing
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI
import RuntimeViewerUI

/// What the activity display says about a report: the segments, which of them go first when the
/// text does not fit, the separators of each style, and the progress (proposal
/// `0071-xcode-activity-progress`). RuntimeViewerAppCore works the activity out as a
/// `ToolbarActivity` and RuntimeViewerAppUI copies it into the state the views take, so these go
/// through both, as the window does.
@Suite("Toolbar activity state")
struct ToolbarActivityStateTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 1000)

    @Test("The state copies every field of the activity")
    func toolbarActivityStateCopiesEveryField() {
        let reportIdentifier = UUID()
        let activity = ToolbarActivity(
            reportIdentifier: reportIdentifier,
            isCompleted: true,
            segments: [
                .init("Indexing", priority: 2, separator: .space),
                .init("Succeeded", priority: 1, isEmphasized: true, separator: .primary),
                .init("Today at 19:33", priority: 3),
            ],
            progress: .determinate(percent: 42),
            activityCount: 3
        )

        let state = ToolbarActivityState(activity)

        #expect(state == ToolbarActivityState(
            reportIdentifier: reportIdentifier,
            isCompleted: true,
            segments: [
                ActivityTextSegment("Indexing", priority: 2, separator: .space),
                ActivityTextSegment("Succeeded", priority: 1, isEmphasized: true, separator: .primary),
                ActivityTextSegment("Today at 19:33", priority: 3),
            ],
            progress: .determinate(percent: 42),
            activityCount: 3
        ))
        #expect(ToolbarActivityState(ToolbarActivity(reportIdentifier: nil, isCompleted: false, segments: [], progress: .indeterminate, activityCount: 0)).progress == .indeterminate)
    }

    @Test("Two activities are equal exactly when their states are")
    func toolbarActivityMatchesFormerDisplayState() {
        let report = ActivityReport(kind: .backgroundIndexing, startDate: Self.start, finishedCount: 1, totalCount: 2, fractionCompleted: 0.5)
        let runningActivity = ToolbarActivity.make(for: .init(report: report, activityCount: 1, nextUpdateDate: nil), sourceName: "My Mac", readyDate: Self.start)
        let idleActivity = ToolbarActivity.make(for: .init(report: nil, activityCount: 0, nextUpdateDate: nil), sourceName: "My Mac", readyDate: Self.start)

        #expect((runningActivity == idleActivity) == (ToolbarActivityState(runningActivity) == ToolbarActivityState(idleActivity)))
        #expect(ToolbarActivityState(runningActivity) == ToolbarActivityState(runningActivity))
    }

    @Test("A running report reads as its kind and its count, the count kept longest")
    func runningReportText() {
        let report = ActivityReport(kind: .backgroundIndexing, startDate: Self.start, finishedCount: 12, totalCount: 48, fractionCompleted: 0.3)

        let state = ToolbarActivityState(ToolbarActivity.make(for: .init(report: report, activityCount: 1, nextUpdateDate: nil), sourceName: "My Mac", readyDate: Self.start))

        #expect(state.segments.plainText(primarySeparator: " │ ") == "Indexing │ 12 of 48 images")
        #expect(state.segments.plainText(primarySeparator: " • ") == "Indexing • 12 of 48 images")
        #expect(state.segments.versionsDroppingSegmentsByPriority().last?.plainText(primarySeparator: " │ ") == "12 of 48 images")
    }

    @Test("Each kind runs under its own title", arguments: [
        (kind: ReportCategory.backgroundIndexing, text: "Indexing │ 0 of 1 image"),
        (kind: .searchableInterfaces, text: "Building Searchable Interfaces │ 0 of 1 image"),
        (kind: .crossReferences, text: "Preparing Cross References │ 0 of 1 image"),
        (kind: .importedTypeNames, text: "Indexing Imported Type Names │ 0 of 1 batch"),
    ])
    func runningTitles(kind: ReportCategory, text: String) {
        let report = ActivityReport(kind: kind, startDate: Self.start, totalCount: 1, fractionCompleted: 0)

        #expect(ActivityText.runningSegments(for: report).map(ActivityTextSegment.init).plainText(primarySeparator: " │ ") == text)
    }

    @Test("A running report shows its progress in whole percent; one without a fraction is indeterminate")
    func runningReportProgress() {
        let measuredReport = ActivityReport(kind: .searchableInterfaces, startDate: Self.start, totalCount: 3, fractionCompleted: 0.375)
        let unmeasuredReport = ActivityReport(kind: .searchableInterfaces, startDate: Self.start, totalCount: 3, fractionCompleted: nil)

        let measuredState = ToolbarActivityState(ToolbarActivity.make(for: .init(report: measuredReport, activityCount: 1, nextUpdateDate: nil), sourceName: "My Mac", readyDate: Self.start))
        let unmeasuredState = ToolbarActivityState(ToolbarActivity.make(for: .init(report: unmeasuredReport, activityCount: 1, nextUpdateDate: nil), sourceName: "My Mac", readyDate: Self.start))

        #expect(measuredState.progress == .determinate(percent: 37))
        #expect(unmeasuredState.progress == .indeterminate)
        #expect(measuredState.isRunning)
    }

    @Test("A fraction counts in whole percent, rounded down", arguments: [
        (fraction: 0.0, percent: 0),
        (fraction: 0.009, percent: 0),
        (fraction: 0.375, percent: 37),
        (fraction: 0.999, percent: 99),
        (fraction: 1.0, percent: 100),
        (fraction: -0.5, percent: 0),
        (fraction: 1.5, percent: 100),
    ])
    func percentOfFraction(fraction: Double, percent: Int) {
        #expect(ActivityText.percent(of: fraction) == percent)
    }

    @Test("A completed report reads as its kind and its outcome, the outcome in bold, the time dropped first", arguments: [
        (kind: ReportCategory.backgroundIndexing, outcome: ActivityReport.Outcome.succeeded, text: "Indexing Succeeded"),
        (kind: .searchableInterfaces, outcome: .succeeded, text: "Searchable Interfaces Built"),
        (kind: .crossReferences, outcome: .succeeded, text: "Cross References Prepared"),
        (kind: .importedTypeNames, outcome: .succeeded, text: "Imported Type Names Indexed"),
        (kind: .backgroundIndexing, outcome: .failed, text: "Indexing Failed"),
        (kind: .crossReferences, outcome: .cancelled, text: "Cross References Cancelled"),
    ])
    func completedReportText(kind: ReportCategory, outcome: ActivityReport.Outcome, text: String) throws {
        let segments = ActivityText.completedSegments(for: kind, completion: .init(outcome: outcome, date: Self.start)).map(ActivityTextSegment.init)

        let versions = segments.versionsDroppingSegmentsByPriority()
        #expect(versions.count == 3)
        #expect(versions[1].plainText(primarySeparator: " │ ") == text)
        #expect(segments.filter(\.isEmphasized).map(\.text) == [String(text.split(separator: " ").last ?? "")])
        let timeSegment = try #require(segments.last)
        #expect(timeSegment.priority == 3)
    }

    @Test("A completed report has no progress and keeps its identity")
    func completedReportState() {
        var report = ActivityReport(kind: .backgroundIndexing, startDate: Self.start, finishedCount: 4, totalCount: 4, fractionCompleted: 1)
        report.completion = .init(outcome: .succeeded, date: Self.start + 5)

        let state = ToolbarActivityState(ToolbarActivity.make(for: .init(report: report, activityCount: 1, nextUpdateDate: nil), sourceName: "My Mac", readyDate: Self.start))

        #expect(state.reportIdentifier == report.id)
        #expect(state.isCompleted)
        #expect(state.isRunning == false)
        #expect(state.progress == nil)
    }

    @Test("Before anything ran, the display reads as the source being ready, the time dropped first")
    func idleText() {
        let state = ToolbarActivityState(ToolbarActivity.make(for: .init(report: nil, activityCount: 0, nextUpdateDate: nil), sourceName: "My Mac", readyDate: Self.start))

        #expect(state.reportIdentifier == nil)
        #expect(state.progress == nil)
        #expect(state.segments.versionsDroppingSegmentsByPriority()[1].plainText(primarySeparator: " │ ") == "My Mac: Ready")
        #expect(state.segments.filter(\.isEmphasized).map(\.text) == ["Ready"])
    }

    @Test("Dropping segments goes from the highest priority number down to a single segment")
    func versionsDropHighestPriorityFirst() {
        let segments = [
            ActivityTextSegment("Build", priority: 3, separator: .primary),
            ActivityTextSegment("Compiling", priority: 2, separator: .primary),
            ActivityTextSegment("12 of 48", priority: 1),
        ]

        let versions = segments.versionsDroppingSegmentsByPriority().map { $0.plainText(primarySeparator: " │ ") }

        #expect(versions == ["Build │ Compiling │ 12 of 48", "Compiling │ 12 of 48", "12 of 48"])
    }
}
