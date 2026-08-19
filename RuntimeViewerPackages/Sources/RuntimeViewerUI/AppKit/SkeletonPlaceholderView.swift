#if os(macOS)

import AppKit
import SnapKit
import UIFoundation

/// Content-shaped loading placeholder: rounded grey bars laid out to mimic
/// the shape of the content that is still being fetched, pulsing gently
/// between full and half opacity.
///
/// This is a *replacement* placeholder rather than an overlay effect (see
/// `NSView.showSkeleton(using:)` for the latter). Call sites hide the real
/// subviews for as long as the placeholder is presented, so data belonging to
/// a previously inspected object is never visible underneath. That is what
/// the Inspector needs: switching `RuntimeObject` must not leave the previous
/// object's class hierarchy or subclass list on screen while the new one
/// loads.
public final class SkeletonPlaceholderView: NSView {
    /// One placeholder bar.
    public struct Bar: Hashable, Sendable {
        public enum Width: Hashable, Sendable {
            /// A fraction of the placeholder's own width. Only usable when the
            /// placeholder gets its width from its container.
            case fraction(CGFloat)
            /// A fixed width in points. Use this when the placeholder sits in
            /// a content-hugging container that has no width of its own — the
            /// bars then define the container's width instead of the reverse.
            case points(CGFloat)
        }

        /// Varying this per row is what keeps the placeholder from reading as
        /// a solid block of grey.
        public var width: Width

        public var height: CGFloat

        public init(width: Width, height: CGFloat) {
            self.width = width
            self.height = height
        }
    }

    /// One placeholder line: an optional leading icon square plus one or more
    /// bars stacked to its trailing side.
    public struct Row: Hashable, Sendable {
        /// Extra leading offset, used to draw stepped shapes such as a class
        /// hierarchy.
        public var leadingInset: CGFloat

        /// Side length of the square drawn before the bars, or `nil` for a
        /// bars-only row.
        public var iconLength: CGFloat?

        /// Bars stacked top to bottom — a title bar alone, or a title bar
        /// plus a shorter subtitle bar.
        public var bars: [Bar]

        public init(leadingInset: CGFloat = 0, iconLength: CGFloat? = nil, bars: [Bar]) {
            self.leadingInset = leadingInset
            self.iconLength = iconLength
            self.bars = bars
        }
    }

    private enum Metrics {
        static let spacingBetweenRows: CGFloat = 10
        static let spacingBetweenBars: CGFloat = 4
        static let spacingAfterIcon: CGFloat = 8
        static let barCornerRadius: CGFloat = 3
        static let iconCornerRadius: CGFloat = 5
    }

    private enum Animation {
        static let key = "SkeletonPlaceholderViewPulse"
        static let minimumOpacity: Float = 0.5
        static let halfCycleDuration: TimeInterval = 0.65
    }

    public var rows: [Row] {
        didSet {
            guard rows != oldValue else { return }
            rebuildRowViews()
        }
    }

    /// Shows the placeholder and runs its pulse, or hides it and stops the
    /// pulse. A hidden placeholder keeps no animation running, so tabs that
    /// are not loading cost nothing.
    public var isPresentingPlaceholder: Bool = false {
        didSet {
            guard isPresentingPlaceholder != oldValue else { return }
            isHidden = !isPresentingPlaceholder
            updatePulseAnimation()
        }
    }

    public init(rows: [Row]) {
        self.rows = rows
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        rebuildRowViews()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Moving between windows drops layer animations; re-add ours so a
        // placeholder that was already presented keeps pulsing.
        updatePulseAnimation()
    }

    // MARK: - Layout

    private func rebuildRowViews() {
        subviews.forEach { $0.removeFromSuperview() }

        var previousRowView: NSView?

        for (rowIndex, row) in rows.enumerated() {
            let rowView = NSView()
            addSubview(rowView)

            rowView.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview()
                if let previousRowView {
                    // Row spacing is a preference, not a requirement: the bar
                    // heights themselves are required, so without give here a
                    // placeholder taller than its container would report a
                    // constraint conflict instead of simply tightening up.
                    make.top.greaterThanOrEqualTo(previousRowView.snp.bottom)
                    make.top.equalTo(previousRowView.snp.bottom).offset(Metrics.spacingBetweenRows).priority(.high)
                } else {
                    make.top.equalToSuperview()
                }
                if rowIndex == rows.count - 1 {
                    make.bottom.lessThanOrEqualToSuperview()
                    make.bottom.equalToSuperview().priority(.high)
                }
            }

            var leadingBarAnchorView: NSView?

            if let iconLength = row.iconLength {
                let iconView = PlaceholderShapeView()
                iconView.cornerRadius = Metrics.iconCornerRadius
                rowView.addSubview(iconView)
                iconView.snp.makeConstraints { make in
                    make.leading.equalToSuperview().offset(row.leadingInset)
                    make.centerY.equalToSuperview()
                    make.width.height.equalTo(iconLength)
                    make.top.greaterThanOrEqualToSuperview()
                    make.bottom.lessThanOrEqualToSuperview()
                }
                leadingBarAnchorView = iconView
            }

            var previousBarView: NSView?

            for (barIndex, bar) in row.bars.enumerated() {
                let barView = PlaceholderShapeView()
                barView.cornerRadius = min(Metrics.barCornerRadius, bar.height / 2)
                rowView.addSubview(barView)

                barView.snp.makeConstraints { make in
                    if let leadingBarAnchorView {
                        make.leading.equalTo(leadingBarAnchorView.snp.trailing).offset(Metrics.spacingAfterIcon)
                    } else {
                        make.leading.equalToSuperview().offset(row.leadingInset)
                    }
                    if let previousBarView {
                        make.top.equalTo(previousBarView.snp.bottom).offset(Metrics.spacingBetweenBars)
                    } else {
                        make.top.equalToSuperview()
                    }
                    if barIndex == row.bars.count - 1 {
                        make.bottom.equalToSuperview()
                    }
                    make.height.equalTo(bar.height)
                    switch bar.width {
                    case .fraction(let fraction):
                        // The fraction is of the placeholder's full width, so
                        // a deeply inset row could otherwise overflow — the
                        // trailing limit wins when they disagree.
                        make.width.equalTo(self).multipliedBy(fraction).priority(.high)
                    case .points(let points):
                        make.width.equalTo(points)
                    }
                    make.trailing.lessThanOrEqualToSuperview()
                }

                previousBarView = barView
            }

            previousRowView = rowView
        }
    }

    // MARK: - Animation

    private func updatePulseAnimation() {
        guard isPresentingPlaceholder, window != nil else {
            layer?.removeAnimation(forKey: Animation.key)
            return
        }
        guard layer?.animation(forKey: Animation.key) == nil else { return }

        let pulseAnimation = CABasicAnimation(keyPath: "opacity")
        pulseAnimation.fromValue = 1.0
        pulseAnimation.toValue = Animation.minimumOpacity
        pulseAnimation.duration = Animation.halfCycleDuration
        pulseAnimation.autoreverses = true
        pulseAnimation.repeatCount = .infinity
        pulseAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulseAnimation, forKey: Animation.key)
    }
}

// MARK: - Presets

extension SkeletonPlaceholderView {
    /// Widths cycled across rows. A fixed pattern rather than a random one so
    /// the placeholder looks identical every time it appears — a reshuffle on
    /// each load would itself read as flicker.
    private static let widthPattern: [CGFloat] = [0.62, 0.45, 0.71, 0.38, 0.55, 0.66, 0.42, 0.58]

    private static func widthMultiplier(at index: Int) -> CGFloat {
        widthPattern[index % widthPattern.count]
    }

    /// Placeholder for the class-hierarchy text: one bar per level, each
    /// stepped a little further in.
    ///
    /// The bars are sized in points because the disclosure area that hosts
    /// them hugs its content — there is no container width to take a fraction
    /// of.
    public static func classHierarchy(levelCount: Int = 5) -> SkeletonPlaceholderView {
        let widestBar: CGFloat = 190
        let rows = (0 ..< levelCount).map { levelIndex in
            Row(
                leadingInset: CGFloat(levelIndex) * 10,
                bars: [Bar(width: .points(widestBar * widthMultiplier(at: levelIndex)), height: 11)]
            )
        }
        return SkeletonPlaceholderView(rows: rows)
    }

    /// Placeholder for a list of `RuntimeObjectCellView` rows: leading icon,
    /// a name bar and a shorter image-name bar.
    public static func runtimeObjectList(rowCount: Int = 5) -> SkeletonPlaceholderView {
        let rows = (0 ..< rowCount).map { rowIndex in
            Row(
                leadingInset: 4,
                iconLength: 20,
                bars: [
                    Bar(width: .fraction(widthMultiplier(at: rowIndex)), height: 11),
                    Bar(width: .fraction(widthMultiplier(at: rowIndex + 3) * 0.6), height: 8),
                ]
            )
        }
        return SkeletonPlaceholderView(rows: rows)
    }
}

// MARK: - Shapes

extension SkeletonPlaceholderView {
    /// A single rounded grey shape — one bar or one icon square.
    private final class PlaceholderShapeView: LayerBackedView {
        /// Deliberately not a system label color: the placeholder sits on a
        /// visual-effect background, where the system greys are either too
        /// faint to read as content or too heavy to read as a placeholder.
        private static let shapeColor = NSColor(name: "SkeletonPlaceholderShape") { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua:
                return NSColor.white.withAlphaComponent(0.13)
            default:
                return NSColor.black.withAlphaComponent(0.10)
            }
        }

        override func setup() {
            super.setup()

            backgroundColor = Self.shapeColor
        }
    }
}

#endif
