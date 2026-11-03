#if os(macOS)

import AppKit
import QuartzCore

/// The progress shape of Xcode 27's window title: `IDEActivityWindowTitleView.ActivityProgressViewStyle.CollapsibleProgressShape`
/// (IDEKit 27.2 27B52, path 0xA5B020), drawn by Core Animation with every one of its values animatable.
///
/// In the largest square of the layer: an arc band of `thickness` from twelve o'clock clockwise to
/// `progress`, with round caps; a centre disc whose hole closes as `centerCollapseProgress` goes
/// from 0 to 1; and the corners of a continuous rounded square that grow out of the circle as
/// `squareRevealProgress` goes from 0 to 1. At the end of a run all three make a solid rounded
/// square. Full spec: `/Volumes/RE/Xcode/27.2-27B52/README.md`, "CollapsibleProgressShape".
final class CollapsibleProgressLayer: CALayer {
    static let animatableKeys: Set<String> = [
        "progress", "thickness", "centerCollapseProgress", "squareRevealProgress", "squareCornerRadiusPercent",
    ]

    /// From 0 to 1: how far round the arc goes.
    @NSManaged var progress: CGFloat

    @NSManaged var thickness: CGFloat

    /// From 0 to 1: the centre hole closing.
    @NSManaged var centerCollapseProgress: CGFloat

    /// From 0 to 1: the rounded square's corners growing out of the circle.
    @NSManaged var squareRevealProgress: CGFloat

    /// The finished square's corner radius as a fraction of its side.
    @NSManaged var squareCornerRadiusPercent: CGFloat

    /// What the shape is filled with.
    var shapeFillColor: CGColor? {
        didSet { setNeedsDisplay() }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let source = layer as? CollapsibleProgressLayer {
            shapeFillColor = source.shapeFillColor
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override class func needsDisplay(forKey key: String) -> Bool {
        animatableKeys.contains(key) || super.needsDisplay(forKey: key)
    }

    override class func defaultValue(forKey key: String) -> Any? {
        switch key {
        case "progress", "thickness", "centerCollapseProgress", "squareRevealProgress":
            return 0 as CGFloat
        case "squareCornerRadiusPercent":
            return 0.2 as CGFloat
        default:
            return super.defaultValue(forKey: key)
        }
    }

    override func draw(in context: CGContext) {
        guard let shapeFillColor else { return }
        let path = Self.path(
            in: bounds,
            progress: progress,
            thickness: thickness,
            centerCollapseProgress: centerCollapseProgress,
            squareRevealProgress: squareRevealProgress,
            squareCornerRadiusPercent: squareCornerRadiusPercent
        )
        context.saveGState()
        // The shape is worked out with the y axis pointing down, as SwiftUI's is.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.addPath(path)
        context.setFillColor(shapeFillColor)
        context.fillPath()
        context.restoreGState()
    }

    /// The shape in `rect`, with y pointing down: the union of the arc band, the centre disc, the
    /// square's corners and the two round caps (`CollapsibleProgressShape.path(in:)`).
    static func path(
        in rect: CGRect,
        progress: CGFloat,
        thickness: CGFloat,
        centerCollapseProgress: CGFloat,
        squareRevealProgress: CGFloat,
        squareCornerRadiusPercent: CGFloat
    ) -> CGPath {
        let side = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let center = CGPoint(x: square.midX, y: square.midY)
        let endAngle = (progress * 360 - 90) * .pi / 180
        let innerSquare = square.insetBy(dx: thickness, dy: thickness)
        let innerEllipse = CGPath(ellipseIn: innerSquare, transform: nil)

        // 1. The arc band: the circle within the wedge from twelve o'clock round to the end angle,
        // without the inner circle.
        let wedge = CGMutablePath()
        wedge.move(to: center)
        wedge.addLine(to: CGPoint(x: square.midX, y: square.minY))
        wedge.addArc(center: center, radius: square.height + 1, startAngle: -.pi / 2, endAngle: endAngle, clockwise: false)
        wedge.closeSubpath()
        var shape = CGPath(ellipseIn: square, transform: nil)
            .intersection(wedge)
            .subtracting(innerEllipse)

        // 2. The centre disc, its hole closing.
        let holeDiameter = max((side - 2 * thickness) * (1 - centerCollapseProgress), 0)
        let hole = CGPath(ellipseIn: CGRect(x: center.x - holeDiameter / 2, y: center.y - holeDiameter / 2, width: holeDiameter, height: holeDiameter), transform: nil)
        shape = shape.union(innerEllipse.subtracting(hole))

        // 3. The square's corners: a continuous rounded square without the circle.
        if squareRevealProgress > 0 {
            let cornerInset = side * 0.1 * (1 - min(squareRevealProgress / 0.1, 1))
            let cornerRadius = (1 - squareRevealProgress) * side / 2 + squareRevealProgress * squareCornerRadiusPercent * side
            let roundedSquare = continuousRoundedRectPath(in: square.insetBy(dx: cornerInset, dy: cornerInset), cornerRadius: cornerRadius)
            shape = shape.union(roundedSquare.subtracting(CGPath(ellipseIn: square.insetBy(dx: 1, dy: 1), transform: nil)))
        }

        // 4. The round caps at both ends of the arc.
        if thickness > 0 {
            let startCap = CGRect(x: square.midX - thickness / 2, y: square.minY, width: thickness, height: thickness)
            let capDistance = side / 2 - thickness / 2
            let endCap = CGRect(
                x: center.x - thickness / 2 + cos(endAngle) * capDistance,
                y: center.y - thickness / 2 + sin(endAngle) * capDistance,
                width: thickness,
                height: thickness
            )
            shape = shape.union(CGPath(ellipseIn: startCap, transform: nil)).union(CGPath(ellipseIn: endCap, transform: nil))
        }
        return shape
    }

    /// A rounded rectangle with continuous corners — the curve of SwiftUI's
    /// `RoundedRectangle(style: .continuous)` and UIKit's rounded rects — while the radius leaves
    /// room for it, and with circular corners beyond, up to a circle.
    static func continuousRoundedRectPath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        let halfSide = min(rect.width, rect.height) / 2
        let radius = min(max(cornerRadius, 0), halfSide)
        // The continuous corner spans 1.528665 times its radius along each edge.
        let continuousLimit = halfSide / 1.52866483
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        guard radius <= continuousLimit else {
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        let path = CGMutablePath()
        func topLeft(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * radius, y: rect.minY + y * radius) }
        func topRight(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x * radius, y: rect.minY + y * radius) }
        func bottomRight(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x * radius, y: rect.maxY - y * radius) }
        func bottomLeft(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * radius, y: rect.maxY - y * radius) }

        path.move(to: topLeft(1.52866483, 0))
        path.addLine(to: topRight(1.52866471, 0))
        path.addCurve(to: topRight(0.66993427, 0.06549600), control1: topRight(1.08849323, 0), control2: topRight(0.86840689, 0))
        path.addLine(to: topRight(0.63149399, 0.07491100))
        path.addCurve(to: topRight(0.07491176, 0.63149399), control1: topRight(0.37282392, 0.16905899), control2: topRight(0.16906013, 0.37282401))
        path.addCurve(to: topRight(0, 1.52866483), control1: topRight(0, 0.86840701), control2: topRight(0, 1.08849299))
        path.addLine(to: bottomRight(0, 1.52866471))
        path.addCurve(to: bottomRight(0.06549569, 0.66993493), control1: bottomRight(0, 1.08849323), control2: bottomRight(0, 0.86840689))
        path.addLine(to: bottomRight(0.07491111, 0.63149399))
        path.addCurve(to: bottomRight(0.63149399, 0.07491111), control1: bottomRight(0.16905883, 0.37282392), control2: bottomRight(0.37282392, 0.16905883))
        path.addCurve(to: bottomRight(1.52866471, 0), control1: bottomRight(0.86840689, 0), control2: bottomRight(1.08849323, 0))
        path.addLine(to: bottomLeft(1.52866483, 0))
        path.addCurve(to: bottomLeft(0.66993397, 0.06549569), control1: bottomLeft(1.08849299, 0), control2: bottomLeft(0.86840701, 0))
        path.addLine(to: bottomLeft(0.63149399, 0.07491111))
        path.addCurve(to: bottomLeft(0.07491100, 0.63149399), control1: bottomLeft(0.37282401, 0.16905883), control2: bottomLeft(0.16906001, 0.37282392))
        path.addCurve(to: bottomLeft(0, 1.52866471), control1: bottomLeft(0, 0.86840689), control2: bottomLeft(0, 1.08849323))
        path.addLine(to: topLeft(0, 1.52866483))
        path.addCurve(to: topLeft(0.06549600, 0.66993397), control1: topLeft(0, 1.08849299), control2: topLeft(0, 0.86840701))
        path.addLine(to: topLeft(0.07491100, 0.63149399))
        path.addCurve(to: topLeft(0.63149399, 0.07491100), control1: topLeft(0.16906001, 0.37282401), control2: topLeft(0.37282401, 0.16906001))
        path.addCurve(to: topLeft(1.52866483, 0), control1: topLeft(0.86840701, 0), control2: topLeft(1.08849299, 0))
        path.closeSubpath()
        return path
    }
}

#endif
