#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

extension NSView {
    public struct SkeletonConfiguration {
        public enum Direction {
            case leftToRight
            case rightToLeft
        }

        public enum Style {
            case full
            case code
        }

        public var style: Style
        public var baseColor: NSColor
        public var highlightColor: NSColor
        public var lineHeight: CGFloat
        public var lineSpacing: CGFloat
        public var cornerRadius: CGFloat
        public var direction: Direction
        public var animationDuration: TimeInterval
        public var angle: CGFloat
        public var contentInsets: NSSize

        public static let `default` = SkeletonConfiguration(
            style: .full,
            baseColor: NSColor.textColor.withAlphaComponent(0.08),
            highlightColor: NSColor.white.withAlphaComponent(0.3),
            lineHeight: 14.0,
            lineSpacing: 8.0,
            cornerRadius: 4.0,
            direction: .leftToRight,
            animationDuration: 1.8,
            angle: 20.0
        )

        public static let codeEditor = SkeletonConfiguration(
            style: .code,
            baseColor: NSColor.textColor.withAlphaComponent(0.08),
            highlightColor: NSColor.white.withAlphaComponent(0.25),
            lineHeight: 15.0,
            lineSpacing: 6.0,
            cornerRadius: 2.0,
            direction: .leftToRight,
            animationDuration: 1.8,
            angle: 20.0
        )

        public init(
            style: Style = .full,
            baseColor: NSColor? = nil,
            highlightColor: NSColor? = nil,
            lineHeight: CGFloat = 14.0,
            lineSpacing: CGFloat = 8.0,
            cornerRadius: CGFloat = 4.0,
            direction: Direction = .leftToRight,
            animationDuration: TimeInterval = 1.5,
            angle: CGFloat = 20.0,
            contentInsets: NSSize = .init(width: 5, height: 5)
        ) {
            self.style = style
            self.baseColor = baseColor ?? NSColor.textColor.withAlphaComponent(0.08)
            self.highlightColor = highlightColor ?? NSColor.textColor.withAlphaComponent(0.3)
            self.lineHeight = lineHeight
            self.lineSpacing = lineSpacing
            self.cornerRadius = cornerRadius
            self.direction = direction
            self.animationDuration = animationDuration
            self.angle = angle
            self.contentInsets = contentInsets
        }
    }

    private final class SkeletonOverlayView: NSView {
        private final class Layer: CALayer {}

        private final class ShapeLayer: CAShapeLayer {}

        private final class GradientLayer: CAGradientLayer {}

        var configuration: SkeletonConfiguration

        // 1. 容器层：用来承载所有内容，并被 mask 裁剪出文字形状
        private let containerLayer = Layer()

        // 2. 遮罩层：绘制圆角矩形（文字形状）
        private let shapeMaskLayer = ShapeLayer()

        // 3. 底色层 (NEW)：永远静止，提供灰色的底
        private let backgroundLayer = Layer()

        // 4. 光效层：负责扫光动画，背景透明
        private let shineLayer = GradientLayer()

        init(frame: NSRect, configuration: SkeletonConfiguration) {
            self.configuration = configuration
            super.init(frame: frame)
            setupLayers()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isFlipped: Bool { true }

        override var wantsUpdateLayer: Bool { true }

        private func setupLayers() {
            wantsLayer = true

            layerContentsRedrawPolicy = .onSetNeedsDisplay

            guard let rootLayer = layer else { return }

            // 1. 根容器 & Mask
            containerLayer.backgroundColor = NSColor.clear.cgColor
            containerLayer.mask = shapeMaskLayer
            rootLayer.addSublayer(containerLayer)

            // 2. 底色层
            backgroundLayer.backgroundColor = configuration.baseColor.cgColor
            containerLayer.addSublayer(backgroundLayer)

            // 3. 光效层 (改动点)
            shineLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
            shineLayer.endPoint = CGPoint(x: 1.0, y: 0.5)

            // 【关键修改】：使用5个点，而不是3个点
            // 0.0 ~ 0.3: 完全透明
            // 0.3 ~ 0.5: 慢慢变亮
            // 0.5: 最亮
            // 0.5 ~ 0.7: 慢慢变暗
            // 0.7 ~ 1.0: 完全透明
            // 这样光晕会非常柔和，不会像一根棍子
            shineLayer.locations = [0.0, 0.3, 0.5, 0.7, 1.0]

            containerLayer.addSublayer(shineLayer)
        }

        override func updateLayer() {
            super.updateLayer()

            backgroundLayer.backgroundColor = configuration.baseColor.cgColor

            // 获取高亮色的 CGColor
            let highlight = configuration.highlightColor.cgColor
            // 极淡的过渡色 (保留原本颜色的 20% 透明度)
            let faint = configuration.highlightColor.withAlphaComponent(configuration.highlightColor.alphaComponent * 0.2).cgColor
            let clear = NSColor.clear.cgColor

            // 【关键修改】：建立 5 级颜色渐变
            // 透明 -> 极淡 -> 高亮 -> 极淡 -> 透明
            shineLayer.colors = [
                clear,
                faint,
                highlight,
                faint,
                clear,
            ]
        }

        override func layout() {
            super.layout()

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            let bounds = self.bounds
            containerLayer.frame = bounds

            // 1. 底色层铺满全屏
            backgroundLayer.frame = bounds

            // 2. 重绘遮罩形状 (文字条)
            setupMaskShape(bounds: bounds)

            // 3. 计算光效层的大小和位置
            let angleRad = configuration.angle * .pi / 180.0
            let extraWidth = bounds.height * abs(tan(angleRad))

            // 【关键修改】：这里 + 100 改成 bounds.width * 1.5
            // 让光条层的实际物理宽度非常宽，这样渐变拉伸得更开，光感更细腻
            let totalWidth = bounds.width + extraWidth + (bounds.width * 1.5)
            let totalHeight = bounds.height * 2.0

            // 将光效层居中放置，稍后通过 transform 移动
            let gradientFrame = CGRect(
                x: (bounds.width - totalWidth) / 2,
                y: (bounds.height - totalHeight) / 2,
                width: totalWidth,
                height: totalHeight
            )

            shineLayer.frame = gradientFrame

            // 应用旋转
            var transform = CATransform3DIdentity
            transform = CATransform3DMakeRotation(-angleRad, 0, 0, 1)
            shineLayer.transform = transform

            CATransaction.commit()

            // 重新启动动画
            startAnimating()
        }

        private func setupMaskShape(bounds: CGRect) {
            let path = CGMutablePath()

            if bounds.width <= 0 || bounds.height <= 0 { return }

            var currentY: CGFloat = configuration.contentInsets.height
            let startX: CGFloat = configuration.contentInsets.width
            let maxAvailableWidth = bounds.width - (configuration.contentInsets.width * 2)

            if maxAvailableWidth <= 0 { return }

            let effectiveRowHeight = configuration.lineHeight + configuration.lineSpacing
            var rowIndex = 0

            while currentY < bounds.height {
                var lineWidth = maxAvailableWidth
                let lineX = startX // 始终左对齐，无缩进

                if configuration.style == .code {
                    // 使用正弦函数生成稳定的伪随机数 (-1.0 ~ 1.0)
                    // 乘以 13.0 是为了让波形跳跃大一点，避免相邻行长度太接近
                    let randomSeed = sin(Double(rowIndex) * 13.0)

                    // 将 -1~1 映射到 0.4~1.0 (即 40% ~ 100% 宽度)
                    // 这样最短的行也不会短于 40%，看起来更像真实内容
                    let widthRatio = CGFloat((randomSeed + 1.0) / 2.0 * 0.6 + 0.4)

                    lineWidth = maxAvailableWidth * widthRatio
                }

                // 绘制圆角矩形
                let rect = CGRect(x: lineX, y: currentY, width: lineWidth, height: configuration.lineHeight)
                let roundedRect = CGPath(roundedRect: rect, cornerWidth: configuration.cornerRadius, cornerHeight: configuration.cornerRadius, transform: nil)
                path.addPath(roundedRect)

                currentY += effectiveRowHeight
                rowIndex += 1
            }

            shapeMaskLayer.path = path
        }

        // MARK: - Animation

        func startAnimating() {
            shineLayer.removeAnimation(forKey: "slide")

            let boundsWidth = bounds.width

            // 动画行程：从左侧外面 -> 右侧外面
            // 因为 layer 已经旋转并居中，我们直接操作 translation.x
            // 只要数值够大，能覆盖屏幕宽度即可
            let startX = -boundsWidth * 1.5
            let endX = boundsWidth * 1.5

            let animation = CABasicAnimation(keyPath: "transform.translation.x")

            if configuration.direction == .leftToRight {
                animation.fromValue = startX
                animation.toValue = endX
            } else {
                animation.fromValue = endX
                animation.toValue = startX
            }

            animation.duration = configuration.animationDuration
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.timingFunction = CAMediaTimingFunction(name: .linear)

            shineLayer.add(animation, forKey: "slide")
        }

        func stopAnimating() {
            shineLayer.removeAllAnimations()
        }
    }

    private final class SkeletonState {
        weak var overlayView: SkeletonOverlayView?
        var originalEditable: Bool = true
        var originalSelectable: Bool = true
        var originalTextColor: NSColor?
    }

    @inline(never) private static var skeletonStateKey: UInt8 = 0

    private var skeletonState: SkeletonState {
        get {
            if let state = objc_getAssociatedObject(self, &Self.skeletonStateKey) as? SkeletonState {
                return state
            }
            let newState = SkeletonState()
            objc_setAssociatedObject(self, &Self.skeletonStateKey, newState, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return newState
        }
    }

    public func showSkeleton(using config: SkeletonConfiguration = .default) {
        if skeletonState.overlayView != nil { return }

        if let textView = self as? NSTextView {
            skeletonState.originalEditable = textView.isEditable
            skeletonState.originalSelectable = textView.isSelectable
            skeletonState.originalTextColor = textView.textColor

            textView.isSelectable = false
            textView.isEditable = false
            textView.textColor = .clear
        }

        let overlay = SkeletonOverlayView(frame: bounds, configuration: config)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.alphaValue = 0
        addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        overlay.startAnimating()

        skeletonState.overlayView = overlay

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            overlay.animator().alphaValue = 1.0
        }
    }

    public func hideSkeleton() {
        guard let overlay = skeletonState.overlayView else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            overlay.animator().alphaValue = 0.0
        } completionHandler: { [self] in
            overlay.stopAnimating()
            overlay.removeFromSuperview()
            skeletonState.overlayView = nil

            if let textView = self as? NSTextView {
                textView.isEditable = skeletonState.originalEditable
                textView.isSelectable = skeletonState.originalSelectable
                textView.textColor = skeletonState.originalTextColor ?? .labelColor
            }
        }
    }
}

#endif
