#if os(macOS)

import AppKit
import UIFoundation

/// The status half of Xcode 26's toolbar Activity View (IDEKit 26.6 `ActivityView`, without its
/// scheme picker, run destination and issue counts): the activity's text, left-aligned as Xcode
/// lays it out when no scheme picker shows, and at the trailing edge the indicator — a progress
/// ring while the activity is under way, the number of activities when there are several.
///
/// From macOS 26 the capsule around it is the toolbar's own glass platter; before, it is a
/// disabled textured button, as Xcode draws it there. A click anywhere sends the control's action.
/// Full spec, with every address: `/Volumes/RE/Xcode/26.6/README.md`, "Toolbar activity view".
public final class ToolbarActivityView: NSControl {
    /// Xcode's Liquid Glass ("Solarium") toolbar: macOS 26 and later.
    static var usesGlassToolbarMetrics: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    struct Metrics {
        var height: CGFloat
        /// Between the indicator and the trailing edge (`horizontalPadding`).
        var trailingPadding: CGFloat

        static let glass = Metrics(height: 24, trailingPadding: 12)
        static let legacy = Metrics(height: 22, trailingPadding: 6)
    }

    static let minimumWidth: CGFloat = 160

    static let maximumWidth: CGFloat = 2000

    /// Above the 200 at which the toolbar pulls an item wide when it measures its maximum.
    static let maximumWidthPriority = NSLayoutConstraint.Priority(450)

    /// The text's leading inset, and the gap it keeps from what follows it.
    static let textInset: CGFloat = 6

    static let indicatorSize: CGFloat = 16

    static let textHeight: CGFloat = 14

    /// The indicator fading in or out, and the layout around it.
    static let indicatorFadeDuration: TimeInterval = 0.5

    /// Another activity's text, or the indicator coming with it: a push from the top that starts
    /// halfway.
    static let activityChangeTransitionDuration: CFTimeInterval = 0.25

    public private(set) var state: ToolbarActivityState?

    /// The text as it shows now: the version chosen for the room there is.
    var displayedText: String {
        statusLabel.stringValue
    }

    /// Whether the indicator shows, or is fading in.
    var isShowingIndicator: Bool {
        isIndicatorShown
    }

    /// The ring's value as the indicator draws it, `nil` while it draws the disc.
    var shownRingValue: ActivityProgressRing.Value? {
        indicatorView.progressRing.isHidden ? nil : indicatorView.progressRing.value
    }

    private let metrics: Metrics = usesGlassToolbarMetrics ? .glass : .legacy

    /// Before macOS 26 only; the glass platter takes its place from 26.
    private let legacyBackgroundButton: NSButton?

    private let textContainerView = LayerBackedView()

    private let statusLabel = Label()

    private let indicatorView = Indicator()

    /// Measures each version of the text the way the label's own cell would draw it.
    private let measuringCell = NSTextFieldCell(textCell: "")

    private var textTrailingWithoutIndicatorConstraint: Constraint?

    private var textTrailingWithIndicatorConstraint: Constraint?

    private var isIndicatorShown = false

    /// The width the last choice of text was made for.
    private var textChoiceWidth: CGFloat = -1

    public init() {
        if Self.usesGlassToolbarMetrics {
            legacyBackgroundButton = nil
        } else {
            let button = NSButton()
            button.bezelStyle = .toolbar
            button.setButtonType(.pushOnPushOff)
            button.title = ""
            button.isEnabled = false
            button.refusesFirstResponder = true
            legacyBackgroundButton = button
        }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: metrics.height))
        setup()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        statusLabel.syncStringValueToolTip = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .left
        statusLabel.allowsExpansionToolTips = true
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .labelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        measuringCell.font = statusLabel.font
        measuringCell.lineBreakMode = .byTruncatingTail

        indicatorView.alphaValue = 0
        indicatorView.isHidden = true

        hierarchy {
            if let legacyBackgroundButton {
                legacyBackgroundButton
            }
            textContainerView.hierarchy {
                statusLabel
            }
            indicatorView
        }

        snp.makeConstraints { make in
            make.height.equalTo(metrics.height)
            make.width.greaterThanOrEqualTo(Self.minimumWidth)
            make.width.lessThanOrEqualTo(Self.maximumWidth).priority(Self.maximumWidthPriority.rawValue)
        }
        legacyBackgroundButton?.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        indicatorView.snp.makeConstraints { make in
            make.size.equalTo(Self.indicatorSize)
            make.centerY.equalToSuperview()
            make.trailing.equalToSuperview().inset(metrics.trailingPadding)
        }
        textContainerView.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(Self.textInset)
            make.centerY.equalToSuperview()
            make.height.equalTo(Self.textHeight)
            textTrailingWithoutIndicatorConstraint = make.trailing.lessThanOrEqualToSuperview().inset(metrics.trailingPadding + Self.textInset).constraint
            textTrailingWithIndicatorConstraint = make.trailing.lessThanOrEqualTo(indicatorView.snp.leading).offset(-2 * Self.textInset).constraint
        }
        textTrailingWithIndicatorConstraint?.deactivate()
        statusLabel.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        updateLegacyBackgroundState()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    // MARK: - State

    /// Shows `newState`. With `animated`, the indicator fades in and out and another activity's
    /// text pushes in from the top, as Xcode's `updateUI()` and `dvt_willLayoutSubview` do.
    public func apply(_ newState: ToolbarActivityState, animated: Bool) {
        let oldState = state
        state = newState
        let isActivityChange = oldState != nil && oldState?.reportIdentifier != newState.reportIdentifier
        let canAnimate = animated && oldState != nil && window != nil

        if isActivityChange, canAnimate {
            textContainerView.layer?.add(Self.activityChangeTransition(), forKey: "activityChange")
        }
        textChoiceWidth = -1
        needsLayout = true

        let shouldShowIndicator = Self.showsIndicator(for: newState)
        // Only while it shows, as Xcode's `updateUI()`: a ring fading out keeps its last value.
        if shouldShowIndicator {
            indicatorView.update(for: newState, animated: canAnimate && !isActivityChange)
        }
        guard shouldShowIndicator != isIndicatorShown else { return }
        isIndicatorShown = shouldShowIndicator
        textTrailingWithIndicatorConstraint?.isActive = shouldShowIndicator
        textTrailingWithoutIndicatorConstraint?.isActive = !shouldShowIndicator
        indicatorView.isHidden = false
        if !canAnimate {
            indicatorView.alphaValue = shouldShowIndicator ? 1 : 0
            indicatorView.isHidden = !shouldShowIndicator
        } else if isActivityChange {
            indicatorView.layer?.add(Self.activityChangeTransition(), forKey: "activityChange")
            indicatorView.alphaValue = shouldShowIndicator ? 1 : 0
            indicatorView.isHidden = !shouldShowIndicator
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.indicatorFadeDuration
                indicatorView.animator().alphaValue = shouldShowIndicator ? 1 : 0
            } completionHandler: { [weak self] in
                guard let self, isIndicatorShown == shouldShowIndicator else { return }
                indicatorView.isHidden = !shouldShowIndicator
            }
        }
    }

    /// Xcode shows the indicator for several activities at once, or for one under way whose
    /// progress is past 0 or not known (`displayedUIState.didset`, IDEKit 26.6 0x547770).
    static func showsIndicator(for state: ToolbarActivityState) -> Bool {
        if state.activityCount >= 2 {
            return true
        }
        guard state.isRunning, let progress = state.progress else { return false }
        switch progress {
        case .determinate(let percent):
            return percent > 0
        case .indeterminate:
            return true
        }
    }

    private static func activityChangeTransition() -> CATransition {
        let transition = CATransition()
        transition.type = .push
        transition.subtype = .fromTop
        transition.duration = activityChangeTransitionDuration
        transition.startProgress = 0.5
        return transition
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        let availableWidth = bounds.width - Self.textInset - metrics.trailingPadding - Self.textInset
            - (isIndicatorShown ? Self.indicatorSize + 2 * Self.textInset : 0)
        guard availableWidth != textChoiceWidth else { return }
        textChoiceWidth = availableWidth
        chooseText(forAvailableWidth: availableWidth)
    }

    /// The longest version of the text narrower than the room, the shortest when none is; the
    /// full text becomes the tooltip whenever a shorter one shows (`orderedStrings(for:)` and
    /// `updateAttributedStringForAvailableWidth()`, IDEKit 26.6).
    private func chooseText(forAvailableWidth availableWidth: CGFloat) {
        let versions = (state?.segments ?? []).versionsDroppingSegmentsByPriority().map(Self.attributedText(for:))
        let chosenIndex = versions.firstIndex { version in
            measuringCell.attributedStringValue = version
            return measuringCell.cellSize.width < availableWidth
        } ?? versions.count - 1
        let chosenText = versions[chosenIndex]
        if statusLabel.attributedStringValue != chosenText {
            statusLabel.attributedStringValue = chosenText
        }
        let isShortened = chosenIndex > 0 || measuringCell.cellSize.width >= availableWidth
        statusLabel.toolTip = isShortened ? versions.first?.string : nil
    }

    /// The text of one version: 11-point system font in the label colour, the emphasized segments
    /// bold, segments joined by their separators (` │ ` for the primary one).
    static func attributedText(for segments: [ActivityTextSegment]) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        let regularAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]
        var emphasizedAttributes = regularAttributes
        emphasizedAttributes[.font] = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)

        let text = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            text.append(NSAttributedString(string: segment.text, attributes: segment.isEmphasized ? emphasizedAttributes : regularAttributes))
            guard index < segments.count - 1, let separator = segment.separator else { continue }
            let separatorText = switch separator {
            case .primary: " \u{2502} "
            case .space: " "
            }
            text.append(NSAttributedString(string: separatorText, attributes: regularAttributes))
        }
        return text
    }

    // MARK: - Clicks

    /// The whole capsule takes the click, whatever it lands on.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        guard let mouseUpEvent = window?.nextEvent(matching: [.leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) else { return }
        let location = convert(mouseUpEvent.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        sendAction(action, to: target)
    }

    // MARK: - Appearance

    @objc private func accessibilityDisplayOptionsDidChange() {
        updateLegacyBackgroundState()
        indicatorView.needsDisplay = true
    }

    /// Xcode turns the button off when the user asks for more contrast.
    private func updateLegacyBackgroundState() {
        legacyBackgroundButton?.state = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .off : .on
    }
}

// MARK: - Indicator

extension ToolbarActivityView {
    /// Xcode's `MultiActionIndicator` (IDEKit 26.6 0x54EF84), without its cancel button: a grey disc
    /// or the progress ring, and the number of activities when there are several, all centred.
    final class Indicator: LayerBackedView {
        private let disc = Disc()

        private let countLabel = Label()

        let progressRing = ActivityProgressRing(ringSize: ToolbarActivityView.indicatorSize)

        /// The count shows up to 9, as Xcode's does.
        static let maximumShownCount = 9

        override func setup() {
            super.setup()
            countLabel.syncStringValueToolTip = false
            countLabel.font = .systemFont(ofSize: 10)
            countLabel.alignment = .center
            countLabel.textColor = .labelColor
            progressRing.isHidden = true
            countLabel.isHidden = true

            hierarchy {
                disc
                progressRing
                countLabel
            }
            disc.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            progressRing.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            countLabel.snp.makeConstraints { make in
                make.center.equalToSuperview()
            }
        }

        /// The ring while the activity shown is under way, with its progress — animated unless
        /// the activity just changed — and the disc otherwise; the count over either.
        func update(for state: ToolbarActivityState, animated: Bool) {
            let ringValue: ActivityProgressRing.Value? = state.isRunning ? state.progress.map {
                switch $0 {
                case .determinate(let percent):
                    .determinate(Double(percent))
                case .indeterminate:
                    .indeterminate
                }
            } : nil
            // While the indicator fades out, the ring keeps its last value.
            if let ringValue {
                progressRing.setValue(ringValue, animated: animated)
            }
            progressRing.isHidden = ringValue == nil
            disc.isHidden = ringValue != nil
            let shownCount = min(state.activityCount, Self.maximumShownCount)
            countLabel.isHidden = shownCount < 2
            countLabel.stringValue = "\(shownCount)"
        }
    }

    /// A 16-point disc in the fourth label colour, as the appearance without vibrancy has it.
    final class Disc: LayerBackedView {
        override func setup() {
            super.setup()
            cornerRadius = ToolbarActivityView.indicatorSize / 2
        }

        override func updateLayer() {
            super.updateLayer()
            let nonVibrantAppearance = NSAppearance(named: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua) ?? effectiveAppearance
            nonVibrantAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            }
        }
    }
}

#endif
