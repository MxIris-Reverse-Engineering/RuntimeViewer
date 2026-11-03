#if os(macOS)

import AppKit
import UIFoundation

/// The progress ring of the toolbar's activity capsule: Xcode's `DVTProgressRing`
/// (DVTUserInterfaceKit 26.6, `init(size:)` 0x1506C8, layer set up at 0x151930).
///
/// A track circle and an arc over it, both an eighth of the size wide with round caps; the arc
/// starts at twelve o'clock and runs clockwise. A new value draws the arc there in 0.6 seconds,
/// easing out. While the progress is not known the arc stays at half a ring and the whole ring
/// spins once a second. Full spec: `/Volumes/RE/Xcode/26.6/README.md`, "Progress indicator".
public final class ActivityProgressRing: LayerBackedView {
    public enum Value: Equatable {
        /// Percent done, 0 to 100.
        case determinate(Double)
        case indeterminate
    }

    /// The ring's side; Xcode's activity view uses 16.
    public let ringSize: CGFloat

    /// The arc's colour; the accent colour when `nil`.
    public var strokeColor: NSColor? {
        didSet { needsDisplay = true }
    }

    public private(set) var value: Value = .determinate(0)

    static let determinateAnimationDuration: CFTimeInterval = 0.6

    static let rotationDuration: CFTimeInterval = 1

    static let rotationAnimationKey = "rotation-animation-key"

    /// The grey of the track when the user asks for more contrast (`0.869` in Xcode).
    static let increasedContrastTrackWhite: CGFloat = 0.869

    /// Spun while the progress is not known; holds the track and the arc.
    private let ringLayer = CALayer()

    private let trackLayer = CAShapeLayer()

    private let arcLayer = CAShapeLayer()

    public init(ringSize: CGFloat = 16) {
        self.ringSize = ringSize
        super.init(frame: NSRect(x: 0, y: 0, width: ringSize, height: ringSize))
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: ringSize, height: ringSize)
    }

    public override func setup() {
        super.setup()
        let lineWidth = ringSize * 0.125
        let bounds = CGRect(x: 0, y: 0, width: ringSize, height: ringSize)
        ringLayer.frame = bounds

        trackLayer.frame = bounds
        trackLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
        trackLayer.fillColor = nil
        trackLayer.lineWidth = lineWidth
        trackLayer.lineCap = .round

        // Starts at twelve o'clock and runs clockwise: the layer's y axis points up.
        let arcPath = CGMutablePath()
        arcPath.addArc(
            center: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: (ringSize - 2) / 2,
            startAngle: .pi / 2,
            endAngle: .pi / 2 - 2 * .pi,
            clockwise: true
        )
        arcLayer.frame = bounds
        arcLayer.path = arcPath
        arcLayer.fillColor = nil
        arcLayer.lineWidth = lineWidth
        arcLayer.lineCap = .round
        arcLayer.strokeEnd = 0

        ringLayer.addSublayer(trackLayer)
        ringLayer.addSublayer(arcLayer)
        layer?.addSublayer(ringLayer)
    }

    public override func layout() {
        super.layout()
        // Centred, so that a frame larger than the ring keeps it in the middle.
        let origin = CGPoint(x: (bounds.width - ringSize) / 2, y: (bounds.height - ringSize) / 2)
        withoutImplicitAnimations {
            ringLayer.frame = CGRect(origin: origin, size: CGSize(width: ringSize, height: ringSize))
        }
    }

    public override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let trackColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                ? NSColor(white: Self.increasedContrastTrackWhite, alpha: 1)
                : NSColor.tertiaryLabelColor
            trackLayer.strokeColor = trackColor.cgColor
            arcLayer.strokeColor = (strokeColor ?? .controlAccentColor).cgColor
        }
    }

    /// Shows `newValue`, animating a determinate change when `animated` is on, as
    /// `-[DVTProgressRing update(progress:animated:)]` does.
    public func setValue(_ newValue: Value, animated: Bool) {
        let oldValue = value
        value = newValue
        switch newValue {
        case .indeterminate:
            arcLayer.removeAllAnimations()
            withoutImplicitAnimations {
                arcLayer.strokeEnd = 0.5
            }
            startRotating()
        case .determinate(let percent):
            let strokeEnd = min(max(percent, 0), 100) / 100
            if case .indeterminate = oldValue {
                stopRotating()
                arcLayer.removeAllAnimations()
                withoutImplicitAnimations {
                    arcLayer.strokeEnd = strokeEnd
                }
                return
            }
            guard arcLayer.strokeEnd != strokeEnd else { return }
            let previousStrokeEnd = arcLayer.presentation()?.strokeEnd ?? arcLayer.strokeEnd
            withoutImplicitAnimations {
                arcLayer.strokeEnd = strokeEnd
            }
            guard animated else { return }
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = previousStrokeEnd
            animation.toValue = strokeEnd
            animation.duration = Self.determinateAnimationDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            arcLayer.add(animation, forKey: "strokeEnd")
        }
    }

    private func startRotating() {
        guard ringLayer.animation(forKey: Self.rotationAnimationKey) == nil else { return }
        // Around the ring's centre, whatever the layer's own anchor.
        ringLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let rotation = CABasicAnimation(keyPath: "transform.rotation")
        rotation.fromValue = 0
        rotation.toValue = -2 * CGFloat.pi
        rotation.duration = Self.rotationDuration
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        ringLayer.add(rotation, forKey: Self.rotationAnimationKey)
    }

    private func stopRotating() {
        ringLayer.removeAnimation(forKey: Self.rotationAnimationKey)
    }
}

/// Runs `changes` with Core Animation's implicit animations turned off.
func withoutImplicitAnimations(_ changes: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    changes()
    CATransaction.commit()
}

#endif
