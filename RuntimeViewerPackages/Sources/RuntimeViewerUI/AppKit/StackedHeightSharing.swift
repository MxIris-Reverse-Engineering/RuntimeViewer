#if os(macOS)

import Foundation

/// How views stacked one under another share a height, the way the sections of the Inspector's References tab share
/// the Inspector: every view gets at least its minimum and at most its preferred height, and every view short of its
/// preferred height ends up as tall as the others short of theirs. So a view whose preferred height fits takes just
/// that, and the views that do not fit split what is left evenly. When even the minimums do not fit, every view gets
/// its minimum and the stack runs past the height; whatever holds the views scrolls then.
public enum StackedHeightSharing {
    /// What one view asks of the height.
    public struct Demand: Equatable, Sendable {
        /// The least the view can do with: its fixed parts, and the first few rows of a list that scrolls.
        public var minimum: CGFloat

        /// Everything the view has to show. Taken as `minimum` when it is less.
        public var preferred: CGFloat

        public init(minimum: CGFloat, preferred: CGFloat) {
            self.minimum = minimum
            self.preferred = preferred
        }
    }

    /// The least height the views take: every one at its minimum, `spacing` apart.
    public static func minimumHeight(of demands: [Demand], spacing: CGFloat) -> CGFloat {
        demands.reduce(0) { $0 + $1.minimum } + totalSpacing(between: demands.count, spacing: spacing)
    }

    /// The views' heights, in order, when they are stacked `spacing` apart in `height`.
    ///
    /// Each view is one level tall, kept between its minimum and its preferred height, and the level is the one at
    /// which the views fill `height` exactly. The heights are not rounded to whole points.
    public static func heights(for demands: [Demand], spacing: CGFloat, in height: CGFloat) -> [CGFloat] {
        let demands = demands.map { Demand(minimum: $0.minimum, preferred: max($0.preferred, $0.minimum)) }
        let availableHeight = height - totalSpacing(between: demands.count, spacing: spacing)

        func clampedHeight(of demand: Demand, atLevel level: CGFloat) -> CGFloat {
            min(max(level, demand.minimum), demand.preferred)
        }

        func totalHeight(atLevel level: CGFloat) -> CGFloat {
            demands.reduce(0) { $0 + clampedHeight(of: $1, atLevel: level) }
        }

        // The total rises with the level, in straight pieces between these.
        let breakpoints = Set(demands.flatMap { [$0.minimum, $0.preferred] }).sorted()
        guard let lowestBreakpoint = breakpoints.first, let highestBreakpoint = breakpoints.last else { return [] }
        if totalHeight(atLevel: highestBreakpoint) <= availableHeight {
            return demands.map(\.preferred)
        }
        if totalHeight(atLevel: lowestBreakpoint) >= availableHeight {
            return demands.map(\.minimum)
        }
        var level = lowestBreakpoint
        for (lowerBreakpoint, upperBreakpoint) in zip(breakpoints, breakpoints.dropFirst()) {
            let lowerTotal = totalHeight(atLevel: lowerBreakpoint)
            let upperTotal = totalHeight(atLevel: upperBreakpoint)
            guard upperTotal >= availableHeight else { continue }
            // Multiplied before dividing, so that whole-point inputs with a whole-point answer give it exactly.
            level = lowerBreakpoint + (availableHeight - lowerTotal) * (upperBreakpoint - lowerBreakpoint) / (upperTotal - lowerTotal)
            break
        }
        return demands.map { clampedHeight(of: $0, atLevel: level) }
    }

    private static func totalSpacing(between viewCount: Int, spacing: CGFloat) -> CGFloat {
        spacing * CGFloat(max(viewCount - 1, 0))
    }
}

#endif
