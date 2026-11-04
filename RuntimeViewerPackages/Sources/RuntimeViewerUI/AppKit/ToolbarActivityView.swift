#if os(macOS)

import AppKit
import UIFoundation

/// Xcode 26's toolbar Activity View (IDEKit 26.6 `ActivityView`, without its run destination and
/// issue counts): the activity's text, and at the trailing edge the indicator — a progress ring while
/// the activity is under way, the number of activities when there are several.
///
/// Made with `showsSourcePicker`, the capsule also holds the runtime source picker at its leading
/// edge, as Xcode holds its scheme picker there, and the text is right-aligned; without it the text is
/// left-aligned, as Xcode lays it out when no scheme picker shows. The text is told it has the room
/// left once the picker has been given `max(56, min(its wanted width, 20 % of the capsule))`; whatever
/// the text does not use goes to the picker, up to its wanted width. Within one activity the picker
/// never widens again once the text has narrowed it, so a text that changes every second does not make
/// it jump; the activity, the capsule's width or the picker's title changing starts over. A pointer over
/// a narrowed picker widens it to its wanted width in 0.2 s while the text gives way in 0.5 s, and half a
/// second after the pointer leaves it narrows again; while its popover shows it stays as it is.
///
/// From macOS 26 the capsule around it is the toolbar's own glass platter; before, it is a
/// disabled textured button, as Xcode draws it there. A click anywhere but on the picker sends the
/// control's action. Full spec, with every address: `/Volumes/RE/Xcode/26.6/README.md`, "Toolbar
/// activity view" and "Scheme picker in the toolbar activity view".
public final class ToolbarActivityView: NSControl {
    /// Xcode's Liquid Glass ("Solarium") toolbar: macOS 26 and later.
    static var usesGlassToolbarMetrics: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    struct Metrics {
        var height: CGFloat
        /// Between the indicator and the trailing edge (`horizontalPadding`).
        var trailingPadding: CGFloat
        /// Where the source picker starts: Xcode's `pathControlLeftPadding` on the macOS 26 design, 0
        /// before it.
        var sourcePickerLeadingInset: CGFloat
        /// What the text's room loses next to the picker's on the macOS 26 design — Xcode charges the
        /// path control's left padding once more when no SDK chooser shows.
        var sourcePickerExtraReserve: CGFloat

        static let glass = Metrics(height: 24, trailingPadding: 12, sourcePickerLeadingInset: 6, sourcePickerExtraReserve: 6)
        static let legacy = Metrics(height: 22, trailingPadding: 6, sourcePickerLeadingInset: 0, sourcePickerExtraReserve: 0)
    }

    /// How the pointer stands with the source picker — Xcode's `SchemePickerHoverState`.
    enum SourcePickerHoverState: Equatable {
        case notHovered
        /// Over a picker that already shows its title whole: its width is held where it is.
        case hoveredWithoutResize
        /// Over a narrowed picker, which widens to `targetWidth`.
        case hovered(targetWidth: CGFloat)
    }

    /// The least the text leaves the picker — Xcode's `absoluteMinimum`.
    static let sourcePickerMinimumReserve: CGFloat = 56

    /// The share of the capsule the text leaves the picker, up to its wanted width — Xcode's
    /// `proportionalMinimum`.
    static let sourcePickerProportionalReserve: CGFloat = 0.2

    /// The picker growing or shrinking on hover — Xcode's `PathControlAnimation`.
    static let sourcePickerResizeDuration: TimeInterval = 0.2

    /// How long a narrowed picker stays wide after the pointer leaves it — Xcode's
    /// `delayedSchemePickerHoverEnded`.
    static let sourcePickerHoverEndDelay: TimeInterval = 0.5

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

    /// Where the text sits in the capsule.
    var statusTextFrame: NSRect {
        textContainerView.frame
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

    /// Xcode's scheme picker in the capsule, when the capsule was made with one.
    public let sourcePicker: RuntimeSourcePicker?

    private(set) var sourcePickerHoverState: SourcePickerHoverState = .notHovered

    /// The narrowest the text has pushed the picker during the activity on show — Xcode's
    /// `perActivityClampedSchemePickerWidth`.
    private(set) var clampedSourcePickerWidth: CGFloat?

    private var sourcePickerHoverEndTask: DispatchWorkItem?

    /// Whether the next layout animates the picker's width and the text's place: after the picker
    /// widened on hover or narrowed again — Xcode's `animateSchemePickerOnNextLayout`.
    private var animatesSourcePickerOnNextLayout = false

    /// Whether the next layout slides the text: after the indicator came or went within one activity.
    private var animatesTextOnNextLayout = false

    private var sourcePickerResizeAnimation: SourcePickerResizeAnimation?

    private var hasCompletedInitialLayout = false

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

    /// - Parameter showsSourcePicker: Whether the capsule holds the runtime source picker at its
    ///   leading edge, with the text right-aligned.
    public init(showsSourcePicker: Bool = false) {
        sourcePicker = showsSourcePicker ? RuntimeSourcePicker(style: .activityView) : nil
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
            if let sourcePicker {
                sourcePicker
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
        // With the picker, the text and the picker share the room by Xcode's rules, which `layout()`
        // works out and sets as frames; without it, constraints keep the text left-aligned.
        if let sourcePicker {
            textContainerView.translatesAutoresizingMaskIntoConstraints = true
            sourcePicker.translatesAutoresizingMaskIntoConstraints = true
            sourcePicker.changeHandler = { [weak self] change in
                self?.sourcePickerDidChange(change)
            }
        } else {
            textContainerView.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(Self.textInset)
                make.centerY.equalToSuperview()
                make.height.equalTo(Self.textHeight)
                textTrailingWithoutIndicatorConstraint = make.trailing.lessThanOrEqualToSuperview().inset(metrics.trailingPadding + Self.textInset).constraint
                textTrailingWithIndicatorConstraint = make.trailing.lessThanOrEqualTo(indicatorView.snp.leading).offset(-2 * Self.textInset).constraint
            }
            textTrailingWithIndicatorConstraint?.deactivate()
        }
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
        if oldState?.reportIdentifier != newState.reportIdentifier {
            // Another activity: the picker may widen again (`displayedUIState.didset`).
            clampedSourcePickerWidth = nil
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
        // The text slides along with the indicator, unless the activity changed under it.
        animatesTextOnNextLayout = canAnimate && !isActivityChange && hasCompletedInitialLayout
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
        if let sourcePicker {
            layoutText(andSourcePicker: sourcePicker)
            return
        }
        let availableWidth = bounds.width - Self.textInset - metrics.trailingPadding - Self.textInset
            - (isIndicatorShown ? Self.indicatorSize + 2 * Self.textInset : 0)
        guard availableWidth != textChoiceWidth else { return }
        textChoiceWidth = availableWidth
        chooseText(forAvailableWidth: availableWidth)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        if newSize.width != frame.width {
            // A capsule of another width starts the picker over (`-[ActivityView setFrameSize:]`).
            clampedSourcePickerWidth = nil
        }
        super.setFrameSize(newSize)
    }

    /// What the text leaves the picker in `capsuleWidth` — Xcode's reserve for the scheme picker in
    /// `SubviewWidthMetrics`: the width it is held at while hovered or while its popover shows,
    /// otherwise `max(56, min(its wanted width, 20 % of the capsule))`.
    func sourcePickerReserve(capsuleWidth: CGFloat, picker: RuntimeSourcePicker) -> CGFloat {
        if picker.isShowingPopover {
            return picker.frame.width
        }
        switch sourcePickerHoverState {
        case .hovered(let targetWidth):
            return targetWidth
        case .hoveredWithoutResize:
            return picker.frame.width
        case .notHovered:
            let proportionalReserve = Self.sourcePickerProportionalReserve * capsuleWidth
            return max(Self.sourcePickerMinimumReserve, min(picker.wantedWidth, proportionalReserve))
        }
    }

    /// Xcode's `dvt_positionSubviewsAndSizeSelfAfterSubviewLayout` with a scheme picker: the text
    /// right-aligned against the indicator or the trailing padding, as wide as its chosen version up
    /// to the room the picker leaves it; then the picker, from its leading inset to the text less 6, no
    /// wider than it wants (`positionAndSizeSchemePicker(using:against:)`).
    private func layoutText(andSourcePicker sourcePicker: RuntimeSourcePicker) {
        let capsuleWidth = bounds.width
        let indicatorReserve = isIndicatorShown ? Self.indicatorSize + Self.textInset : 0
        let pickerReserve = sourcePickerReserve(capsuleWidth: capsuleWidth, picker: sourcePicker)
        let availableWidth = max(
            0,
            capsuleWidth - (pickerReserve + metrics.sourcePickerExtraReserve + Self.textInset) - metrics.trailingPadding - indicatorReserve
        )
        if availableWidth != textChoiceWidth {
            textChoiceWidth = availableWidth
            chooseText(forAvailableWidth: availableWidth)
        }
        let scale = window?.backingScaleFactor ?? 2
        let textWidth = min(statusLabel.intrinsicContentSize.width, availableWidth)
        let textFrame = NSRect(
            x: capsuleWidth - metrics.trailingPadding - indicatorReserve - textWidth,
            y: ((bounds.height - Self.textHeight) / 2 * scale).rounded(.down) / scale,
            width: textWidth,
            height: Self.textHeight
        )
        let animatesSourcePicker = animatesSourcePickerOnNextLayout && hasCompletedInitialLayout && window != nil
        let animatesText = (animatesSourcePicker || animatesTextOnNextLayout) && window != nil
        animatesSourcePickerOnNextLayout = false
        animatesTextOnNextLayout = false
        if animatesText, textContainerView.frame != textFrame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.indicatorFadeDuration
                textContainerView.animator().frame = textFrame
            }
        } else {
            textContainerView.frame = textFrame
        }
        hasCompletedInitialLayout = true

        // While its popover shows, the picker stays where it is.
        guard !sourcePicker.isShowingPopover else { return }
        let room = textFrame.minX - Self.textInset
        let wantedWidth = sourcePicker.wantedWidth
        if room < wantedWidth {
            clampedSourcePickerWidth = min(room, clampedSourcePickerWidth ?? .greatestFiniteMagnitude)
        }
        let pickerWidth: CGFloat = switch sourcePickerHoverState {
        case .hovered(let targetWidth):
            min(targetWidth, room)
        case .hoveredWithoutResize:
            min(sourcePicker.frame.width, room)
        case .notHovered:
            clampedSourcePickerWidth ?? min(wantedWidth, room)
        }
        let pickerHeight = sourcePicker.metrics.height
        let pickerOrigin = NSPoint(
            x: metrics.sourcePickerLeadingInset,
            y: ((bounds.height - pickerHeight) / 2 * scale).rounded(.down) / scale
        )
        resizeSourcePicker(sourcePicker, to: max(0, pickerWidth), origin: pickerOrigin, animated: animatesSourcePicker)
    }

    /// Sets the picker's frame, or — after it widened on hover or narrowed again — moves its width
    /// there over 0.2 s, frame by frame, as Xcode's `PathControlAnimation` does.
    private func resizeSourcePicker(_ sourcePicker: RuntimeSourcePicker, to width: CGFloat, origin: NSPoint, animated: Bool) {
        let height = sourcePicker.metrics.height
        sourcePicker.setFrameOrigin(origin)
        if let sourcePickerResizeAnimation, sourcePickerResizeAnimation.isAnimating {
            guard sourcePickerResizeAnimation.targetWidth != width else { return }
            sourcePickerResizeAnimation.stop()
        }
        sourcePickerResizeAnimation = nil
        guard animated, sourcePicker.frame.width != width else {
            sourcePicker.setFrameSize(NSSize(width: width, height: height))
            return
        }
        let animation = SourcePickerResizeAnimation(
            startWidth: sourcePicker.frame.width,
            targetWidth: width,
            duration: Self.sourcePickerResizeDuration
        ) { [weak sourcePicker] currentWidth in
            sourcePicker?.setFrameSize(NSSize(width: currentWidth, height: height))
        }
        sourcePickerResizeAnimation = animation
        animation.start()
    }

    // MARK: - Source picker hover

    /// Xcode's `hoveredSchemePickerComponent.didset` and `schemePickerMenuIsShowing.didset`: a pointer
    /// over a narrowed picker widens it; one leaving lets it narrow half a second later, unless its
    /// popover shows; a popover closing with the pointer elsewhere narrows it at once.
    private func sourcePickerDidChange(_ change: RuntimeSourcePicker.Change) {
        guard let sourcePicker else { return }
        switch change {
        case .hover:
            if sourcePicker.isHovered {
                sourcePickerHoverEndTask?.cancel()
                sourcePickerHoverEndTask = nil
                if !sourcePicker.showsWholeComponent {
                    setSourcePickerHoverState(.hovered(targetWidth: sourcePicker.wantedWidth))
                } else if case .hovered = sourcePickerHoverState {
                    // Keeps an expansion already under way (`expandHoveredSchemePicker(to: nil)`).
                } else {
                    setSourcePickerHoverState(.hoveredWithoutResize)
                }
            } else if !sourcePicker.isShowingPopover {
                scheduleSourcePickerHoverEnd()
            }
        case .popover:
            if !sourcePicker.isShowingPopover, !sourcePicker.isHovered {
                sourcePickerHoverEndTask?.cancel()
                sourcePickerHoverEndTask = nil
                setSourcePickerHoverState(.notHovered)
            }
            needsLayout = true
        case .wantedWidth:
            // Another source: the picker may widen again (`.preferredSizeDidChange`).
            clampedSourcePickerWidth = nil
            textChoiceWidth = -1
            needsLayout = true
        }
    }

    private func scheduleSourcePickerHoverEnd() {
        sourcePickerHoverEndTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                sourcePickerHoverEndTask = nil
                setSourcePickerHoverState(.notHovered)
            }
        }
        sourcePickerHoverEndTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sourcePickerHoverEndDelay, execute: task)
    }

    /// Xcode animates into a widening and out of one, never between the other two states
    /// (`schemePickerHoverState.didset`).
    func setSourcePickerHoverState(_ newState: SourcePickerHoverState) {
        let oldState = sourcePickerHoverState
        guard newState != oldState else { return }
        sourcePickerHoverState = newState
        if case .hovered = newState {
            animatesSourcePickerOnNextLayout = true
        } else if case .hovered = oldState {
            animatesSourcePickerOnNextLayout = true
        }
        textChoiceWidth = -1
        needsLayout = true
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

    /// The source picker takes the clicks on it; the rest of the capsule takes every other click,
    /// whatever it lands on.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitView = super.hitTest(point) else { return nil }
        if let sourcePicker, hitView === sourcePicker {
            return sourcePicker
        }
        return self
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

// MARK: - Source picker resize

extension ToolbarActivityView {
    /// Xcode's `PathControlAnimation`: an ease-in-out `NSAnimation` that sets the picker's width on
    /// every frame from its raw progress — so, as Xcode's, the width itself moves linearly.
    final class SourcePickerResizeAnimation: NSAnimation {
        let startWidth: CGFloat

        let targetWidth: CGFloat

        private let widthHandler: (CGFloat) -> Void

        init(startWidth: CGFloat, targetWidth: CGFloat, duration: TimeInterval, widthHandler: @escaping (CGFloat) -> Void) {
            self.startWidth = startWidth
            self.targetWidth = targetWidth
            self.widthHandler = widthHandler
            super.init(duration: duration, animationCurve: .easeInOut)
            animationBlockingMode = .nonblocking
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var currentProgress: NSAnimation.Progress {
            didSet {
                widthHandler(startWidth + (targetWidth - startWidth) * CGFloat(currentProgress))
            }
        }
    }
}

#endif
