import Foundation

/// One piece of an activity's text, as Xcode builds its activity text from
/// `IDEActivityReportStringSegment`s: when the text does not fit, whole segments are dropped, the
/// highest `priority` number first, before the rest is truncated.
public struct ActivityTextSegment: Hashable, Sendable {
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

extension Array where Element == ActivityTextSegment {
    /// The versions of the text to try, longest first: all the segments, then again without the
    /// segment of the highest priority number, and so on down to the last segment — Xcode's
    /// `orderedStrings(for:)`. A separator is kept only where another segment follows it.
    public func versionsDroppingSegmentsByPriority() -> [[ActivityTextSegment]] {
        guard !isEmpty else { return [[]] }
        var versions: [[ActivityTextSegment]] = [self]
        var remaining = self
        while remaining.count > 1 {
            let highestPriority = remaining.map(\.priority).max() ?? 0
            guard let index = remaining.lastIndex(where: { $0.priority == highestPriority }) else { break }
            remaining.remove(at: index)
            versions.append(remaining)
        }
        return versions
    }

    /// The text as one string, each primary separator written as `primarySeparator`.
    public func plainText(primarySeparator: String) -> String {
        var text = ""
        for (index, segment) in enumerated() {
            text += segment.text
            guard index < count - 1, let separator = segment.separator else { continue }
            switch separator {
            case .primary:
                text += primarySeparator
            case .space:
                text += " "
            }
        }
        return text
    }
}

/// What a window's activity display shows: the toolbar capsule below macOS 27, the window title's
/// progress ring and subtitle from macOS 27.
public struct ToolbarActivityState: Hashable, Sendable {
    /// How far the activity shown is.
    public enum Progress: Hashable, Sendable {
        /// Percent done, 0 to 100, as Xcode's reports count it.
        case determinate(percent: Int)
        /// Under way, with nothing to tell how far.
        case indeterminate
    }

    /// The report shown; `nil` when none is. Another value means another activity took the place
    /// of the one shown, which the display animates differently from the same activity changing.
    public var reportIdentifier: UUID?

    /// The report shown has ended; its text is its outcome.
    public var isCompleted: Bool

    public var segments: [ActivityTextSegment]

    /// `nil` when no run is shown, or the one shown has ended.
    public var progress: Progress?

    /// The runs under way, plus the report shown when it is not one of them; 0 while none is shown.
    public var activityCount: Int

    public init(reportIdentifier: UUID?, isCompleted: Bool, segments: [ActivityTextSegment], progress: Progress?, activityCount: Int) {
        self.reportIdentifier = reportIdentifier
        self.isCompleted = isCompleted
        self.segments = segments
        self.progress = progress
        self.activityCount = activityCount
    }

    /// Whether a run is shown and has not ended.
    public var isRunning: Bool {
        reportIdentifier != nil && !isCompleted
    }
}

