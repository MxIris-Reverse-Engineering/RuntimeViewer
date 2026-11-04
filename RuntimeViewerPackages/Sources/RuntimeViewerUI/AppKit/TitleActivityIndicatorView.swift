#if os(macOS)

import AppKit
import QuartzCore
import UIFoundation

/// The activity indicator of Xcode 27's window title, drawn where the document's icon is:
/// `IDEActivityWindowTitleView.documentIconProgressIndicator` with its `ActivityProgressViewStyle`
/// (IDEKit 27.2 27B52, 0xA526A0 and 0xA57FC4), in Core Animation.
///
/// While a run goes on, a ring takes the icon's place: a track in the secondary fill and an arc in
/// the accent colour, which springs to each new value, spins while the progress is not known and
/// turns once more when the progress goes back. When the run ends, the arc fills the circle and the
/// track fades; 0.35 seconds later the centre closes and the corners grow into a rounded square;
/// 0.45 seconds after the end the square clears and the icon fades in — the ring turns back into the
/// icon. A new run plays it backwards. With nothing running the icon shows. A click anywhere sends
/// the control's action. Full spec: `/Volumes/RE/Xcode/27.2-27B52/README.md`, "Activity progress in
/// the window title".
public final class TitleActivityIndicatorView: NSControl {
    /// The slot the indicator sits in, as the icon's frame.
    public static let slotSize: CGFloat = 18

    /// The ring overhangs the slot by a point on every side: its frame is a line of 16-point system
    /// text tall (`lineHeight`, 20 with SF Pro).
    static let ringSize: CGFloat = {
        let font = NSFont.systemFont(ofSize: 16)
        return ceil(font.ascender + abs(font.descender) + font.leading)
    }()

    /// The ring is a seventh of its size thick.
    static var thickness: CGFloat { ringSize / 7 }

    /// The arc never shows less than this, nor more than `visualMaximumBeforeCompletion` until the
    /// run is done.
    static let visualMinimum: CGFloat = 0.05

    static let visualMaximumBeforeCompletion: CGFloat = 0.82

    /// The arc while the progress is not known.
    static let indeterminateVisual: CGFloat = 0.33

    /// The finished square's corner radius as a fraction of its side.
    static let roundedSquareRadiusPercent: CGFloat = 0.26

    /// The value springs: `.spring(response: 0.5, dampingFraction: 0.85)`.
    static let valueSpring = Spring(response: 0.5, dampingFraction: 0.85)

    /// The icon taking over: `.spring(response: 0.5, dampingFraction: 1)`.
    static let settleSpring = Spring(response: 0.5, dampingFraction: 1)

    /// The square going away when a new run starts: `.spring(response: 0.25, dampingFraction: 0.85)`.
    static let retractSpring = Spring(response: 0.25, dampingFraction: 0.85)

    /// The extra turn when the progress goes back: `.spring(response: 1, dampingFraction: 1)`.
    static let rollbackSpring = Spring(response: 1, dampingFraction: 1)

    static let collapseDelay: CFTimeInterval = 0.35

    static let completionContentDelay: CFTimeInterval = 0.45

    static let retractDelay: CFTimeInterval = 0.15

    static let rollbackDuration: TimeInterval = 1

    /// A quarter turn every quarter of a second while the progress is not known.
    static let indeterminateStep: CGFloat = 0.25

    static let indeterminateStepDuration: TimeInterval = 0.25

    /// The count shows up to 99, as Xcode's does.
    static let maximumShownCount = 99

    /// What fills the slot when no run is under way, and what the ring turns into: the document's
    /// icon, drawn at its own size and centred on the slot. One larger than the slot overhangs it, as
    /// Xcode's project frame does; `TitleDocumentIcon` makes them that way.
    public var icon: NSImage? {
        didSet { needsDisplay = true }
    }

    /// The window is the key window: the slot is half transparent otherwise.
    public private(set) var isInKeyWindow = true

    // MARK: Layers

    /// Holds the ring at the centre of the slot, overhanging it.
    private let ringContainerLayer = CALayer()

    private let trackLayer = CAShapeLayer()

    private let shapeLayer = CollapsibleProgressLayer()

    private let iconLayer = CALayer()

    private let countLabel = Label()

    // MARK: Style state (`ActivityProgressViewStyle.LazyState`)

    /// The fraction shown last; `nil` while the progress is not known.
    private var fractionCompleted: Double? = 1

    private var hasAppeared = false

    private var shouldRotateLinearly = false

    private var shouldRotateWithSpring = false

    private var rotations: CGFloat = 0

    private var isRollingBack = false

    private var collapseCenter = false

    private var centerWasCollapsed = false

    private var showingCompletionContent = false

    private var activityCount = 0

    /// Changes after the current one, so a run that ends while its completion is still playing
    /// does not finish what was scheduled for the run before.
    private var sequenceGeneration = 0

    private var windowObservations: [NSObjectProtocol] = []

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.slotSize, height: Self.slotSize))
        setup()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        windowObservations.forEach(NotificationCenter.default.removeObserver)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: Self.slotSize, height: Self.slotSize)
    }

    public override var wantsUpdateLayer: Bool { true }

    private func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        let ringBounds = CGRect(x: 0, y: 0, width: Self.ringSize, height: Self.ringSize)
        ringContainerLayer.bounds = ringBounds
        ringContainerLayer.masksToBounds = false

        trackLayer.frame = ringBounds
        // `Circle().strokeBorder(lineWidth:)`: the stroke stays inside the circle.
        trackLayer.path = CGPath(ellipseIn: ringBounds.insetBy(dx: Self.thickness / 2, dy: Self.thickness / 2), transform: nil)
        trackLayer.fillColor = nil
        trackLayer.lineWidth = Self.thickness

        shapeLayer.frame = ringBounds
        shapeLayer.thickness = Self.thickness
        shapeLayer.squareCornerRadiusPercent = Self.roundedSquareRadiusPercent

        // The icon's slot is 18 by 18 in the ring's frame. The icon draws at its own size, centred
        // on the slot and not scaled down to it: a glyph larger than the slot overhangs it.
        let iconInset = (Self.ringSize - Self.slotSize) / 2
        iconLayer.frame = ringBounds.insetBy(dx: iconInset, dy: iconInset)
        iconLayer.contentsGravity = .center

        ringContainerLayer.addSublayer(trackLayer)
        ringContainerLayer.addSublayer(shapeLayer)
        ringContainerLayer.addSublayer(iconLayer)
        layer?.addSublayer(ringContainerLayer)

        countLabel.syncStringValueToolTip = false
        countLabel.alignment = .center
        countLabel.lineBreakMode = .byClipping
        countLabel.font = Self.countFont
        countLabel.isHidden = true
        countLabel.alphaValue = 0
        addSubview(countLabel)
        countLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.lessThanOrEqualTo(Self.ringSize - 2 * Self.thickness)
        }

        jumpToEndOfRun()
    }

    /// `.font(.system(size: 11, weight: .regular, design: .rounded)).monospacedDigit()`.
    static let countFont: NSFont = {
        let baseFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        guard let roundedDescriptor = baseFont.fontDescriptor.withDesign(.rounded) else { return baseFont }
        return NSFont(descriptor: roundedDescriptor, size: 11) ?? baseFont
    }()

    // MARK: - Layout and appearance

    public override func layout() {
        super.layout()
        withoutImplicitAnimations {
            ringContainerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        shapeLayer.contentsScale = scale
        iconLayer.contentsScale = scale
        trackLayer.contentsScale = scale
        shapeLayer.setNeedsDisplay()
        needsDisplay = true
    }

    public override func updateLayer() {
        super.updateLayer()
        let scale = window?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackLayer.strokeColor = NSColor.secondarySystemFill.cgColor
            shapeLayer.shapeFillColor = NSColor.controlAccentColor.cgColor
            // Drawn here, so an icon that draws for the appearance follows it.
            iconLayer.contents = icon?.layerContents(forContentsScale: scale)
        }
        countLabel.textColor = isInKeyWindow ? .secondaryLabelColor : .tertiaryLabelColor
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        windowObservations.forEach(NotificationCenter.default.removeObserver)
        windowObservations = []
        guard let newWindow else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservations.append(NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateKeyWindowAppearance()
                }
            })
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateKeyWindowAppearance()
    }

    /// `.opacity(controlActiveState == .key ? 1 : 0.5)` on the slot.
    private func updateKeyWindowAppearance() {
        isInKeyWindow = window?.isKeyWindow ?? true
        alphaValue = isInKeyWindow ? 1 : 0.5
        needsDisplay = true
    }

    // MARK: - State

    /// Shows the progress of the activity `state` shows, the way Xcode 27 maps a report's progress
    /// (`progress` getter, 0xA54638): nothing running, a finished run, and a run at 0 show the icon;
    /// a run whose progress is not known spins.
    public func apply(_ state: ToolbarActivityState, animated: Bool) {
        setFractionCompleted(Self.fractionCompleted(for: state), animated: animated)
        setActivityCount(state.activityCount, animated: animated)
    }

    /// The fraction the ring shows for `state`: 1, the icon, for nothing running, a finished run or
    /// a run at 0; `nil` for a run whose progress is not known.
    static func fractionCompleted(for state: ToolbarActivityState) -> Double? {
        switch state.progress {
        case .determinate(let percent) where state.isRunning && percent > 0:
            min(Double(percent), 100) / 100
        case .indeterminate where state.isRunning:
            nil
        default:
            1
        }
    }

    func setFractionCompleted(_ newFraction: Double?, animated: Bool) {
        let oldFraction = fractionCompleted
        fractionCompleted = newFraction
        guard animated, hasAppeared else {
            hasAppeared = true
            newFraction == 1 ? jumpToEndOfRun() : jumpToRun(fractionCompleted: newFraction)
            return
        }
        let wasIndeterminate = oldFraction == nil
        let isIndeterminate = newFraction == nil
        let wasComplete = oldFraction == 1
        let isComplete = newFraction == 1

        // The value, and the track, follow `visual` with the value spring.
        animateShapeProgress(to: centerWasCollapsed && !isComplete ? 1 : visual, spring: Self.valueSpring)
        animate(trackLayer, keyPath: "opacity", to: isComplete ? 0 : 1, spring: Self.valueSpring)

        // `onChange(of: fractionCompleted)`: going back turns the ring once more.
        if let oldFraction, let newFraction, newFraction < oldFraction, !isComplete {
            rollBack()
        }
        // `onChange(of: isIndeterminate)`.
        if isIndeterminate != wasIndeterminate {
            if isIndeterminate {
                shouldRotateLinearly = true
            } else {
                shouldRotateLinearly = false
                shouldRotateWithSpring = true
            }
            rotateIndeterminateSpinner()
        }
        // `onChange(of: isComplete)`.
        if isComplete != wasComplete {
            isComplete ? playCompletion() : playRetraction(isDeterminate: !isIndeterminate)
        }
    }

    /// The arc's length for the progress shown.
    private var visual: CGFloat {
        Self.visualProgress(for: fractionCompleted)
    }

    /// The arc's length for a fraction: a third of the ring while it is not known, the full ring once
    /// done, and in between from 0.05 to 0.82, so a run just started shows and one nearly done does
    /// not look finished.
    static func visualProgress(for fractionCompleted: Double?) -> CGFloat {
        guard let fractionCompleted else { return indeterminateVisual }
        guard fractionCompleted < 1 else { return 1 }
        return visualMinimum + CGFloat(fractionCompleted) * (visualMaximumBeforeCompletion - visualMinimum)
    }

    /// The end of a run: arc full, track gone, centre closed, square shown and cleared, icon on.
    private func jumpToEndOfRun() {
        sequenceGeneration += 1
        shouldRotateLinearly = false
        centerWasCollapsed = true
        collapseCenter = true
        showingCompletionContent = true
        withoutImplicitAnimations {
            removeAllAnimations()
            shapeLayer.progress = 1
            shapeLayer.centerCollapseProgress = 1
            shapeLayer.squareRevealProgress = 1
            shapeLayer.opacity = 0
            trackLayer.opacity = 0
            iconLayer.opacity = 1
        }
    }

    /// A run under way, as a view that appears with it shows it: no sequence, no spin — Xcode's
    /// rotation flags start off, so a ring that appears already indeterminate spins only once the
    /// progress changes.
    private func jumpToRun(fractionCompleted: Double?) {
        sequenceGeneration += 1
        centerWasCollapsed = false
        collapseCenter = false
        showingCompletionContent = false
        withoutImplicitAnimations {
            removeAllAnimations()
            shapeLayer.progress = visual
            shapeLayer.centerCollapseProgress = 0
            shapeLayer.squareRevealProgress = 0
            shapeLayer.opacity = 1
            trackLayer.opacity = 1
            iconLayer.opacity = 0
        }
    }

    private func removeAllAnimations() {
        shapeLayer.removeAllAnimations()
        trackLayer.removeAllAnimations()
        iconLayer.removeAllAnimations()
        ringContainerLayer.removeAllAnimations()
        rotations = 0
        ringContainerLayer.setValue(0, forKeyPath: "transform.rotation.z")
    }

    /// `onChange(of: isComplete)` turning true (closure #7): the arc fills and the track fades now;
    /// the centre closes into the rounded square after 0.35 seconds; after 0.45 seconds the square
    /// clears and the icon fades in.
    private func playCompletion() {
        sequenceGeneration += 1
        centerWasCollapsed = true
        collapseCenter = true
        animate(shapeLayer, keyPath: "centerCollapseProgress", to: 1, spring: Self.valueSpring, delay: Self.collapseDelay)
        animate(shapeLayer, keyPath: "squareRevealProgress", to: 1, spring: Self.valueSpring, delay: Self.collapseDelay)
        showingCompletionContent = true
        animate(shapeLayer, keyPath: "opacity", to: 0, spring: Self.settleSpring, delay: Self.completionContentDelay)
        animate(iconLayer, keyPath: "opacity", to: 1, spring: Self.settleSpring, delay: Self.completionContentDelay)
    }

    /// `onChange(of: isComplete)` turning false: the square and the icon go at once; 0.15 seconds
    /// later the arc retracts from the full circle to the progress, turning once more.
    private func playRetraction(isDeterminate: Bool) {
        sequenceGeneration += 1
        let generation = sequenceGeneration
        guard showingCompletionContent || collapseCenter else { return }
        showingCompletionContent = false
        collapseCenter = false
        animate(shapeLayer, keyPath: "opacity", to: 1, spring: Self.retractSpring)
        animate(iconLayer, keyPath: "opacity", to: 0, spring: Self.retractSpring)
        animate(shapeLayer, keyPath: "centerCollapseProgress", to: 0, spring: Self.retractSpring)
        animate(shapeLayer, keyPath: "squareRevealProgress", to: 0, spring: Self.retractSpring)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retractDelay) { [weak self] in
            guard let self, sequenceGeneration == generation else { return }
            centerWasCollapsed = false
            animateShapeProgress(to: visual, spring: Self.valueSpring)
            if isDeterminate, !isRollingBack {
                rollBack()
            }
        }
    }

    /// One more turn, springing, and nothing else rolls back for a second.
    private func rollBack() {
        guard !isRollingBack else { return }
        isRollingBack = true
        animateRotation(to: rotations + 1, spring: Self.rollbackSpring)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rollbackDuration) { [weak self] in
            self?.isRollingBack = false
        }
    }

    /// A quarter turn each quarter second while the progress is not known; once it is, the ring
    /// springs on to the next whole turn (`rotateIndeterminateSpinner()`, 0xA59F0C).
    private func rotateIndeterminateSpinner() {
        if shouldRotateLinearly {
            animateRotation(to: rotations + Self.indeterminateStep, linearDuration: Self.indeterminateStepDuration)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.indeterminateStepDuration) { [weak self] in
                guard let self, shouldRotateLinearly else { return }
                rotateIndeterminateSpinner()
            }
        } else if shouldRotateWithSpring {
            shouldRotateWithSpring = false
            animateRotation(to: rotations.rounded(.up), spring: Self.valueSpring)
        }
    }

    private func setActivityCount(_ newCount: Int, animated: Bool) {
        activityCount = newCount
        countLabel.stringValue = "\(min(newCount, Self.maximumShownCount))"
        // Shown for several activities while a known progress is short of done.
        let showsCount = newCount >= 2 && (fractionCompleted.map { $0 < 1 } ?? false)
        let isShown = !countLabel.isHidden && countLabel.alphaValue > 0
        guard animated, showsCount != isShown else {
            countLabel.isHidden = !showsCount
            countLabel.alphaValue = showsCount ? 1 : 0
            return
        }
        countLabel.isHidden = false
        // `.transition(.opacity.combined(with: .blur(radius: 1)))` under `.spring(response: 0.5,
        // dampingFraction: 1)`: the fade, without the one-point blur.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.settleSpring.response
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            countLabel.animator().alphaValue = showsCount ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, countLabel.alphaValue == 0 else { return }
            countLabel.isHidden = true
        }
    }

    // MARK: - Animations

    private func animateShapeProgress(to newValue: CGFloat, spring: Spring) {
        animate(shapeLayer, keyPath: "progress", to: newValue, spring: spring)
    }

    /// SwiftUI's rotation, clockwise for a positive number of turns; Core Animation turns the other
    /// way for a positive angle on an unflipped layer.
    private func animateRotation(to newRotations: CGFloat, spring: Spring? = nil, linearDuration: CFTimeInterval? = nil) {
        let oldAngle = -rotations * 2 * .pi
        let newAngle = -newRotations * 2 * .pi
        rotations = newRotations
        let animation: CABasicAnimation
        if let spring {
            animation = spring.animation(keyPath: "transform.rotation.z")
        } else {
            animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.duration = linearDuration ?? 0
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
        }
        animation.isAdditive = true
        animation.fromValue = oldAngle - newAngle
        animation.toValue = 0
        withoutImplicitAnimations {
            ringContainerLayer.setValue(newAngle, forKeyPath: "transform.rotation.z")
        }
        ringContainerLayer.add(animation, forKey: nil)
    }

    /// Moves `keyPath` of `layer` to `newValue` and springs there from where it shows now, adding to
    /// whatever is still under way — as SwiftUI does when a change interrupts another.
    private func animate(_ layer: CALayer, keyPath: String, to newValue: CGFloat, spring: Spring, delay: CFTimeInterval = 0) {
        let oldValue = (layer.value(forKeyPath: keyPath) as? NSNumber).map { CGFloat($0.doubleValue) } ?? newValue
        guard oldValue != newValue else { return }
        withoutImplicitAnimations {
            layer.setValue(newValue, forKeyPath: keyPath)
        }
        let animation = spring.animation(keyPath: keyPath)
        animation.isAdditive = true
        animation.fromValue = oldValue - newValue
        animation.toValue = 0
        if delay > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: nil)
    }

    // MARK: - Clicks

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
}

extension TitleActivityIndicatorView {
    /// A SwiftUI `.spring(response:dampingFraction:)`, which Core Animation's
    /// `CASpringAnimation(perceptualDuration:bounce:)` reproduces: the response is the perceptual
    /// duration, and the bounce is one less the damping fraction.
    struct Spring {
        var response: CFTimeInterval
        var dampingFraction: CGFloat

        func animation(keyPath: String) -> CASpringAnimation {
            let animation = CASpringAnimation(perceptualDuration: response, bounce: 1 - dampingFraction)
            animation.keyPath = keyPath
            animation.duration = animation.settlingDuration
            return animation
        }
    }
}

#endif
