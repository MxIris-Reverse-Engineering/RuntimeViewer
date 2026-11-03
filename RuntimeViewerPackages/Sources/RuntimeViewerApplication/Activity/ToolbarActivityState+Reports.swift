import Foundation
import RuntimeViewerUI

extension ToolbarActivityState {
    /// Nothing has run in the window yet: `<source>: Ready │ <time>`, the time dropped first.
    static func idle(sourceName: String, readyDate: Date) -> ToolbarActivityState {
        ToolbarActivityState(
            reportIdentifier: nil,
            isCompleted: false,
            segments: [
                ActivityTextSegment("\(sourceName): ", priority: 1),
                ActivityTextSegment("Ready", priority: 1, isEmphasized: true, separator: .primary),
                ActivityTextSegment(ActivityText.dateText(readyDate), priority: 3),
            ],
            progress: nil,
            activityCount: 0
        )
    }

    /// The state of a selection: idle when it shows no report.
    static func make(for selection: ActivityReportSelector.Selection, sourceName: String, readyDate: Date) -> ToolbarActivityState {
        guard let report = selection.report else {
            return .idle(sourceName: sourceName, readyDate: readyDate)
        }
        guard let completion = report.completion else {
            return ToolbarActivityState(
                reportIdentifier: report.id,
                isCompleted: false,
                segments: ActivityText.runningSegments(for: report),
                progress: report.fractionCompleted.map { .determinate(percent: ActivityText.percent(of: $0)) } ?? .indeterminate,
                activityCount: selection.activityCount
            )
        }
        return ToolbarActivityState(
            reportIdentifier: report.id,
            isCompleted: true,
            segments: ActivityText.completedSegments(for: report.kind, completion: completion),
            progress: nil,
            activityCount: selection.activityCount
        )
    }
}

/// The words of the activity display.
enum ActivityText {
    /// `Indexing │ 12 of 48 images`: the count goes last and stays longest.
    static func runningSegments(for report: ActivityReport) -> [ActivityTextSegment] {
        let title = runningTitle(of: report.kind)
        guard report.totalCount > 0 else {
            return [ActivityTextSegment(title, priority: 1)]
        }
        let noun = report.totalCount == 1 ? "image" : "images"
        return [
            ActivityTextSegment(title, priority: 2, separator: .primary),
            ActivityTextSegment("\(report.finishedCount) of \(report.totalCount) \(noun)", priority: 1),
        ]
    }

    /// `Indexing Succeeded │ Today at 19:33`, as Xcode's `Build Succeeded │ Today at 19:33`.
    static func completedSegments(for kind: ReportCategory, completion: ActivityReport.Completion) -> [ActivityTextSegment] {
        [
            ActivityTextSegment(subject(of: kind), priority: 2, separator: .space),
            ActivityTextSegment(outcomeText(completion.outcome, of: kind), priority: 1, isEmphasized: true, separator: .primary),
            ActivityTextSegment(dateText(completion.date), priority: 3),
        ]
    }

    static func runningTitle(of kind: ReportCategory) -> String {
        switch kind {
        case .backgroundIndexing:
            "Indexing"
        case .searchableInterfaces:
            "Building Searchable Interfaces"
        case .crossReferences:
            "Preparing Cross References"
        }
    }

    static func subject(of kind: ReportCategory) -> String {
        switch kind {
        case .backgroundIndexing:
            "Indexing"
        case .searchableInterfaces:
            "Searchable Interfaces"
        case .crossReferences:
            "Cross References"
        }
    }

    static func outcomeText(_ outcome: ActivityReport.Outcome, of kind: ReportCategory) -> String {
        switch (outcome, kind) {
        case (.succeeded, .backgroundIndexing):
            "Succeeded"
        case (.succeeded, .searchableInterfaces):
            "Built"
        case (.succeeded, .crossReferences):
            "Prepared"
        case (.failed, _):
            "Failed"
        case (.cancelled, _):
            "Cancelled"
        }
    }

    /// A fraction as Xcode's whole percent: a run counts as started only once it reaches 1.
    static func percent(of fractionCompleted: Double) -> Int {
        Int((min(max(fractionCompleted, 0), 1) * 100).rounded(.down))
    }

    /// `Today at 19:33`, relative to today, as Xcode's date segments.
    static func dateText(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}
