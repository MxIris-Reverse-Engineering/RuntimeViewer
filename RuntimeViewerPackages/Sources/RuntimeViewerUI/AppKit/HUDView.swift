#if os(macOS)

import AppKit

open class HUDView: NSView {
    public struct Configuration: Hashable {
        public struct ShadowProperties: Hashable {
            public var opacity: Float
            public var radius: CGFloat
            public var offset: CGSize
            public var color: NSColor

            public init(opacity: Float, radius: CGFloat, offset: CGSize, color: NSColor) {
                self.opacity = opacity
                self.radius = radius
                self.offset = offset
                self.color = color
            }

            public func hash(into hasher: inout Hasher) {
                hasher.combine(opacity)
                hasher.combine(radius)
                hasher.combine(offset.width)
                hasher.combine(offset.height)
                hasher.combine(color.hashValue)
            }
        }

        public struct BackgroundProperties: Hashable {
            public var cornerRadius: CGFloat
            public var material: NSVisualEffectView.Material
            public var blendingMode: NSVisualEffectView.BlendingMode

            public init(
                cornerRadius: CGFloat = 20,
                material: NSVisualEffectView.Material = .hudWindow,
                blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
            ) {
                self.material = material
                self.blendingMode = blendingMode
                self.cornerRadius = cornerRadius
            }
        }

        public struct TextProperties: Hashable {
            public var font: NSFont
            public var color: NSColor
            public var alignment: NSTextAlignment
            public var maximumNumberOfLines: Int

            public init(
                font: NSFont = .systemFont(ofSize: 14, weight: .medium),
                color: NSColor = .labelColor,
                alignment: NSTextAlignment = .center,
                maximumNumberOfLines: Int = 3
            ) {
                self.font = font
                self.color = color
                self.alignment = alignment
                self.maximumNumberOfLines = maximumNumberOfLines
            }
        }

        public struct ImageProperties: Hashable {
            public var tintColor: NSColor?
            public var preferredSymbolConfiguration: NSImage.SymbolConfiguration?

            public init(
                tintColor: NSColor? = nil,
                preferredSymbolConfiguration: NSImage.SymbolConfiguration? = nil
            ) {
                self.preferredSymbolConfiguration = preferredSymbolConfiguration
                self.tintColor = tintColor
            }
        }

        // MARK: - Properties

        public var title: String?
        public var image: NSImage?
        public var duration: TimeInterval

        public var windowSize: CGSize = .init(width: 160, height: 160)
        public var contentInsets: NSEdgeInsets = .init(top: 20, left: 12, bottom: 20, right: 12)
        public var spacing: CGFloat = 20

        public var textProperties: TextProperties
        public var imageProperties: ImageProperties
        public var shadowProperties: ShadowProperties?
        public var backgroundProperties: BackgroundProperties

        // MARK: - Initializer

        public init(
            title: String? = nil,
            image: NSImage? = nil,
            duration: TimeInterval = 1.0
        ) {
            self.title = title
            self.image = image
            self.duration = duration
            self.backgroundProperties = BackgroundProperties()
            self.textProperties = TextProperties()
            self.imageProperties = ImageProperties()
        }

        public static func standard() -> Configuration {
            return Configuration()
        }

        public static func success() -> Configuration {
            var config = Configuration()
            config.imageProperties.tintColor = .systemGreen
            config.imageProperties.preferredSymbolConfiguration = .init(pointSize: 40, weight: .semibold)
            return config
        }

        public static func error() -> Configuration {
            var config = Configuration()
            config.imageProperties.tintColor = .systemRed
            config.shadowProperties = ShadowProperties(
                opacity: 0.3,
                radius: 15,
                offset: CGSize(width: 0, height: -5),
                color: .black
            )
            return config
        }
    }

    public final var configuration: Configuration {
        didSet {
            if oldValue != configuration {
                setNeedsUpdateConfiguration()
            }
        }
    }

    public final var configurationUpdateHandler: ((HUDView) -> Void)?

    private lazy var backgroundEffectView: NSVisualEffectView = {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.masksToBounds = true
        return visualEffectView
    }()

    private lazy var contentStackView: NSStackView = {
        let stackView = NSStackView()
        stackView.distribution = .fill
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()

    private lazy var imageView: NSImageView = {
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentTintColor = .labelColor
        return imageView
    }()

    private lazy var label: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.alignment = .center
        return label
    }()

    public init(configuration: Configuration) {
        self.configuration = configuration
        super.init(frame: .zero)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        self.configuration = .standard()
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setupHierarchy()
        updateConfiguration()
    }

    open func setNeedsUpdateConfiguration() {
        updateConfiguration()
    }

    open func updateConfiguration() {
        configurationUpdateHandler?(self)

        let configuration = configuration

        backgroundEffectView.material = configuration.backgroundProperties.material
        backgroundEffectView.blendingMode = configuration.backgroundProperties.blendingMode
        backgroundEffectView.layer?.cornerRadius = configuration.backgroundProperties.cornerRadius

        if var image = configuration.image {
            if let preferredSymbolConfiguration = configuration.imageProperties.preferredSymbolConfiguration, let newImage = image.withSymbolConfiguration(preferredSymbolConfiguration) {
                image = newImage
            }
            imageView.image = image
            imageView.contentTintColor = configuration.imageProperties.tintColor
            if imageView.superview == nil {
                contentStackView.insertArrangedSubview(imageView, at: 0)
            }
        } else {
            imageView.removeFromSuperview()
        }

        if let title = configuration.title {
            label.stringValue = title
            label.font = configuration.textProperties.font
            label.textColor = configuration.textProperties.color
            label.alignment = configuration.textProperties.alignment
            label.maximumNumberOfLines = configuration.textProperties.maximumNumberOfLines
            if label.superview == nil {
                contentStackView.addArrangedSubview(label)
            }
        } else {
            label.removeFromSuperview()
        }

        contentStackView.spacing = configuration.spacing
        contentStackView.edgeInsets = configuration.contentInsets

        needsDisplay = true
    }

    public override final var wantsUpdateLayer: Bool { true }

    public override final func updateLayer() {
        guard let layer = layer else { return }
        let backgroundProperties = configuration.backgroundProperties
        let shadowProperties = configuration.shadowProperties
        if let shadow = shadowProperties {
            layer.shadowColor = shadow.color.cgColor
            layer.shadowOpacity = shadow.opacity
            layer.shadowRadius = shadow.radius
            layer.shadowOffset = shadow.offset
            let path = CGPath(
                roundedRect: CGRect(origin: .zero, size: configuration.windowSize),
                cornerWidth: backgroundProperties.cornerRadius,
                cornerHeight: backgroundProperties.cornerRadius,
                transform: nil
            )
            layer.shadowPath = path
        } else {
            layer.shadowOpacity = 0
            layer.shadowPath = nil
        }
    }

    private func setupHierarchy() {
        addSubview(backgroundEffectView)
        backgroundEffectView.addSubview(contentStackView)

        NSLayoutConstraint.activate([
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStackView.centerXAnchor.constraint(equalTo: backgroundEffectView.centerXAnchor),
            contentStackView.centerYAnchor.constraint(equalTo: backgroundEffectView.centerYAnchor),
            contentStackView.widthAnchor.constraint(lessThanOrEqualTo: backgroundEffectView.widthAnchor),
            contentStackView.heightAnchor.constraint(lessThanOrEqualTo: backgroundEffectView.heightAnchor),
        ])
    }

    fileprivate func animateIn() async {
        alphaValue = 0
        return await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1.0
            } completionHandler: {
                continuation.resume()
            }
        }
    }

    fileprivate func animateOut() async {
        return await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0.0
            } completionHandler: {
                continuation.resume()
            }
        }
    }
}

extension NSWindow {
    public func showHUD(with configuration: HUDView.Configuration) {
        Task { @MainActor in
            self.contentView?.subviews
                .compactMap { $0 as? HUDView }
                .forEach { $0.removeFromSuperview() }

            guard let contentView = self.contentView else { return }

            let hud = HUDView(configuration: configuration)
            contentView.addSubview(hud)

            hud.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hud.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                hud.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                hud.widthAnchor.constraint(equalToConstant: configuration.windowSize.width),
                hud.heightAnchor.constraint(equalToConstant: configuration.windowSize.height),
            ])

            await hud.animateIn()

            try? await Task.sleep(nanoseconds: UInt64(configuration.duration * 1_000_000_000))

            guard hud.superview != nil else { return }

            await hud.animateOut()

            hud.removeFromSuperview()
        }
    }

    public func showHUD(text: String, image: NSImage? = nil) {
        var config = HUDView.Configuration.standard()
        config.title = text
        config.image = image
        showHUD(with: config)
    }
}

// extension NSEdgeInsets: @retroactive Hashable {
//    public func hash(into hasher: inout Hasher) {
//        hasher.combine(top)
//        hasher.combine(left)
//        hasher.combine(right)
//        hasher.combine(bottom)
//    }
//
//    public static func == (lhs: Self, rhs: Self) -> Bool {
//        return lhs.top == rhs.top && lhs.left == rhs.left && lhs.right == rhs.right && lhs.bottom == rhs.bottom
//    }
// }

#endif
