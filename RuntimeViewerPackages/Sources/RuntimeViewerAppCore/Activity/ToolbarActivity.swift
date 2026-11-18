import Foundation

/// What a window's activity display shows: the report on screen, its text as segments, its
/// progress and how many runs there are.
///
/// It is the value of RuntimeViewerUI's `ToolbarActivityState`, which the toolbar's views take and
/// which this module cannot name; RuntimeViewerAppUI copies it over field by field
/// (`ToolbarActivityState.init(_:)`). Two activities are equal exactly when the two states would be,
/// so `ToolbarActivityPresenter` drops repeats and holds back changes on this value as it would on
/// the state.
public struct ToolbarActivity: Hashable, Sendable {
    /// One piece of the text, as Xcode builds its activity text from
    /// `IDEActivityReportStringSegment`s: when the text does not fit, whole segments are dropped,
    /// the highest `priority` number first, before the rest is truncated.
    public struct Segment: Hashable, Sendable {
        /// What goes between this segment and the next one, when there is a next one.
        public enum Separator: Hashable, Sendable {
            /// The separator between the parts of an activity: ` │ ` in Xcode 26's toolbar capsule,
            /// ` • ` in Xcode 27's window title.
            case primary
            case space
        }

        public var text: String

        /// The lower the number, the longer the segment stays when the text does not fit.
        public var priority: Int

        /// Drawn bold in the toolbar capsule: the outcome of a run, and "Ready".
        public var isEmphasized: Bool

        public var separator: Separator?

        public init(_ text: String, priority: Int, isEmphasized: Bool = false, separator: Separator? = nil) {
            self.text = text
            self.priority = priority
            self.isEmphasized = isEmphasized
            self.separator = separator
        }
    }

    public enum Progress: Hashable, Sendable {
        /// A whole percent, as Xcode shows it.
        case determinate(percent: Int)
        case indeterminate
    }

    /// The report shown, `nil` while the source is idle.
    public var reportIdentifier: UUID?

    public var isCompleted: Bool

    public var segments: [Segment]

    /// `nil` for a completed report and while idle.
    public var progress: Progress?

    /// How many runs there are, the one shown included.
    public var activityCount: Int

    public init(reportIdentifier: UUID?, isCompleted: Bool, segments: [Segment], progress: Progress?, activityCount: Int) {
        self.reportIdentifier = reportIdentifier
        self.isCompleted = isCompleted
        self.segments = segments
        self.progress = progress
        self.activityCount = activityCount
    }
}

extension ToolbarActivity {
    /// Nothing has run in the window yet: `<source>: Ready │ <time>`, the time dropped first.
    static func idle(sourceName: String, readyDate: Date) -> ToolbarActivity {
        ToolbarActivity(
            reportIdentifier: nil,
            isCompleted: false,
            segments: [
                Segment("\(sourceName): ", priority: 1),
                Segment("Ready", priority: 1, isEmphasized: true, separator: .primary),
                Segment(ActivityText.dateText(readyDate), priority: 3),
            ],
            progress: nil,
            activityCount: 0
        )
    }

    /// The activity of a selection: idle when it shows no report.
    static func make(for selection: ActivityReportSelector.Selection, sourceName: String, readyDate: Date) -> ToolbarActivity {
        guard let report = selection.report else {
            return .idle(sourceName: sourceName, readyDate: readyDate)
        }
        guard let completion = report.completion else {
            return ToolbarActivity(
                reportIdentifier: report.id,
                isCompleted: false,
                segments: ActivityText.runningSegments(for: report),
                progress: report.fractionCompleted.map { .determinate(percent: ActivityText.percent(of: $0)) } ?? .indeterminate,
                activityCount: selection.activityCount
            )
        }
        return ToolbarActivity(
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
    static func runningSegments(for report: ActivityReport) -> [ToolbarActivity.Segment] {
        let title = runningTitle(of: report.kind)
        guard report.totalCount > 0 else {
            return [ToolbarActivity.Segment(title, priority: 1)]
        }
        let noun = report.totalCount == 1 ? "image" : "images"
        return [
            ToolbarActivity.Segment(title, priority: 2, separator: .primary),
            ToolbarActivity.Segment("\(report.finishedCount) of \(report.totalCount) \(noun)", priority: 1),
        ]
    }

    /// `Indexing Succeeded │ Today at 19:33`, as Xcode's `Build Succeeded │ Today at 19:33`.
    static func completedSegments(for kind: ReportCategory, completion: ActivityReport.Completion) -> [ToolbarActivity.Segment] {
        [
            ToolbarActivity.Segment(subject(of: kind), priority: 2, separator: .space),
            ToolbarActivity.Segment(outcomeText(completion.outcome, of: kind), priority: 1, isEmphasized: true, separator: .primary),
            ToolbarActivity.Segment(dateText(completion.date), priority: 3),
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
        // The reporter tracks no manual loads; the words are there for when it does.
        case .manualLoading:
            "Loading"
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
        case .manualLoading:
            "Manual Loading"
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
        case (.succeeded, .manualLoading):
            "Loaded"
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
