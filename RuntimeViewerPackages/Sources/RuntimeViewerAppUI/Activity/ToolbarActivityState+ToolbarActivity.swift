import RuntimeViewerAppCore
import RuntimeViewerUI

extension ToolbarActivityState {
    /// The state the toolbar's activity views take for `activity`, which RuntimeViewerAppCore
    /// works out: every field copied as it is.
    public init(_ activity: ToolbarActivity) {
        self.init(
            reportIdentifier: activity.reportIdentifier,
            isCompleted: activity.isCompleted,
            segments: activity.segments.map(ActivityTextSegment.init),
            progress: activity.progress.map(ToolbarActivityState.Progress.init),
            activityCount: activity.activityCount
        )
    }
}

extension ActivityTextSegment {
    init(_ segment: ToolbarActivity.Segment) {
        self.init(
            segment.text,
            priority: segment.priority,
            isEmphasized: segment.isEmphasized,
            separator: segment.separator.map(ActivityTextSegment.Separator.init)
        )
    }
}

extension ActivityTextSegment.Separator {
    init(_ separator: ToolbarActivity.Segment.Separator) {
        switch separator {
        case .primary:
            self = .primary
        case .space:
            self = .space
        }
    }
}

extension ToolbarActivityState.Progress {
    init(_ progress: ToolbarActivity.Progress) {
        switch progress {
        case .determinate(let percent):
            self = .determinate(percent: percent)
        case .indeterminate:
            self = .indeterminate
        }
    }
}
