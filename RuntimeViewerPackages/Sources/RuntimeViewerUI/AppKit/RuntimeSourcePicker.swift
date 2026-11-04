#if os(macOS)

import AppKit

/// The toolbar's runtime source picker: Xcode's scheme picker with a single component — the icon and
/// the name of the source the window is on — drawn the way DVTKit draws a path component in the
/// configuration IDEKit gives its scheme picker, and sending its action on mouse-down.
///
/// There is one style per Xcode. `.activityView` is Xcode 26's picker at the leading edge of the
/// toolbar's activity capsule (IDEKit 26.6 `ActivityView.schemePicker`, which `ToolbarActivityView`
/// lays out); `.toolbar` is Xcode 27's, in the middle of the toolbar (IDEKit 27.2
/// `IDESchemePickerToolbarView`, which `RuntimeSourcePickerToolbarView` stands for). Specs, with every
/// address: `/Volumes/RE/Xcode/26.6/README.md`, "Scheme picker in the toolbar activity view", and
/// `/Volumes/RE/Xcode/27.2-27B52/README.md`, "Scheme picker in the middle of the toolbar".
///
/// - The component fills the picker, whatever width the owner gives it (DVTKit's
///   `lastComponentFillsWidth`); `wantedWidth` is the width that shows it whole.
/// - A picture icon fits a square box — 16 points in the capsule, 18 in the middle. In the middle a
///   symbol icon takes its own size instead, configured for the title's point size at medium weight
///   and large scale, as DVTKit sizes a symbol in a large path control; that is how Xcode 27 draws a
///   run destination's device glyph.
/// - A title too long for that width is clipped, never ellipsized, and fades out over its last
///   10 points.
/// - The highlight — a capsule of 5 % black, or 5 % white in a dark appearance — shows while the
///   pointer is over the picker and while `isShowingPopover`; in the activity capsule a down chevron
///   comes with it.
/// - The action goes on mouse-down, so that a popover shown from it follows the button: a drag into
///   the popover chooses a row on release.
public final class RuntimeSourcePicker: NSControl {
    public enum Style: Sendable {
        /// Xcode 26's, inside the toolbar's activity capsule.
        case activityView
        /// Xcode 27's, in the middle of the toolbar.
        case toolbar
    }

    /// What the picker shows before its title.
    public enum Icon: Equatable {
        /// A picture, such as an app's or a file's icon, drawn in the style's square box at its
        /// aspect ratio.
        case image(NSImage)

        /// A symbol image in the colours its configuration gives it, such as a device glyph. Xcode
        /// 27's style draws it at its own size once the style's point size, weight and scale are
        /// applied over that configuration; Xcode 26's fits it in the box like a picture.
        case symbol(NSImage)

        /// The same image in the same role: the picker redraws and relays out for nothing less.
        public static func == (leftIcon: Icon, rightIcon: Icon) -> Bool {
            switch (leftIcon, rightIcon) {
            case let (.image(leftImage), .image(rightImage)), let (.symbol(leftImage), .symbol(rightImage)):
                leftImage === rightImage
            default:
                false
            }
        }
    }

    /// What changed that the picker's owner lays it out by.
    enum Change {
        /// The pointer entered or left the picker.
        case hover
        /// The popover opened or closed.
        case popover
        /// The title or the icon changed, and with them the width the picker wants.
        case wantedWidth
    }

    struct Metrics: Equatable {
        var font: NSFont

        /// The picker's height: the activity capsule's, or the toolbar view's.
        var height: CGFloat

        /// DVTKit's left divider: from the picker's leading edge to its icon.
        var leadingInset: CGFloat

        /// DVTKit's right divider: from the title to the picker's trailing edge.
        var trailingInset: CGFloat

        /// The box a picture icon fits, square.
        var iconSize: CGFloat

        /// What a symbol icon is drawn with at its own size, applied over its own configuration, or
        /// `nil` where a symbol fits the box like a picture. DVTKit's `_resetSymbolConfig` for a
        /// large path control: the font's point size, medium weight, large scale.
        var symbolConfiguration: NSImage.SymbolConfiguration?

        /// The highlight's height before its vertical insets, centred in the picker.
        var highlightHeight: CGFloat

        /// Xcode 26 before the macOS 26 design starts the highlight 5 points in and keeps it 1 point
        /// clear of its box above and below.
        var highlightLeadingInset: CGFloat

        var highlightVerticalInset: CGFloat

        /// Whether the highlight is a capsule (radius half its height) rather than a 4-point round rect.
        var drawsCapsuleHighlight: Bool

        /// Whether the highlight comes with a down chevron, centred in the trailing inset.
        var showsHoverChevron: Bool

        /// Xcode 26's in the activity capsule: `ActivityViewToolbarViewController` makes the path
        /// control large with an 11-point font and capsule highlights from the macOS 26 design, and
        /// leaves it small, padding its first item, before it.
        static func activityView(usesGlassMetrics: Bool) -> Metrics {
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
            if usesGlassMetrics {
                return Metrics(
                    font: font,
                    height: 24,
                    leadingInset: 6,
                    trailingInset: 15,
                    iconSize: 16,
                    symbolConfiguration: nil,
                    highlightHeight: 24,
                    highlightLeadingInset: 0,
                    highlightVerticalInset: 0,
                    drawsCapsuleHighlight: true,
                    showsHoverChevron: true
                )
            }
            return Metrics(
                font: font,
                height: 22,
                leadingInset: 7,
                trailingInset: 14,
                iconSize: 16,
                symbolConfiguration: nil,
                highlightHeight: 21,
                highlightLeadingInset: 5,
                highlightVerticalInset: 1,
                drawsCapsuleHighlight: false,
                showsHoverChevron: true
            )
        }

        /// Xcode 27's in the middle of the toolbar: a large path control, whose font DVTKit resets
        /// to the system font at that size, with capsule highlights as tall as the toolbar view.
        static let toolbar: Metrics = {
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large))
            return Metrics(
                font: font,
                height: 28,
                leadingInset: 6,
                trailingInset: 6,
                iconSize: 18,
                symbolConfiguration: NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium, scale: .large),
                highlightHeight: 28,
                highlightLeadingInset: 0,
                highlightVerticalInset: 0,
                drawsCapsuleHighlight: true,
                showsHoverChevron: false
            )
        }()
    }

    /// DVTKit's `iconTitleSpacing`.
    static let iconTitleSpacing: CGFloat = 4

    /// What `sizeWanted` adds to the component's width.
    static let wantedWidthAllowance: CGFloat = 2

    /// The trailing stretch of a clipped title that fades out.
    static let titleFadeWidth: CGFloat = 10

    /// A title wider than its room by more than this fades; less, and it is only clipped.
    static let titleFadeThreshold: CGFloat = 0.9

    /// DVTKit draws no title in a component with no more room than this.
    static let minimumTitleRoom: CGFloat = 3

    /// The chevron keeps this much of the trailing inset clear on its far side, in a capsule.
    static let chevronTrailingMargin: CGFloat = 3

    /// The highlight's fill: 5 % of black, or of white in a dark appearance —
    /// `DVTTheme.hoveredScopeControlColor`.
    static let highlightColor = NSColor(name: "RuntimeSourcePicker.highlight") { appearance in
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.05)
    }

    public let style: Style

    let metrics: Metrics

    /// The source's name.
    public var title: String = "" {
        didSet {
            guard title != oldValue else { return }
            wantedWidthDidChange()
        }
    }

    /// The source's icon.
    public var icon: Icon? {
        didSet {
            guard icon != oldValue else { return }
            drawnIcon = icon.map { Self.makeDrawnIcon(for: $0, metrics: metrics) }
            wantedWidthDidChange()
        }
    }

    /// The icon as the picker draws it: DVTKit's `cachedConfiguredIcon`.
    private(set) var drawnIcon: DrawnIcon?

    struct DrawnIcon {
        /// The image drawn: a symbol with the style's configuration applied over its own, or the
        /// icon's image as given.
        var image: NSImage

        /// The slot the icon takes: the configured symbol's own size, or the style's box.
        var size: NSSize

        /// Whether the image is drawn in its own colours. A picture that is a template is tinted
        /// like the title instead.
        var isSymbol: Bool
    }

    /// DVTKit's `_iconSize`: with a large path control's metrics a symbol icon takes its own size
    /// once `iconApplyingSymbolConfiguration:` has merged the configuration into the symbol's own
    /// (which is what keeps a device glyph's palette); anything else takes the box.
    private static func makeDrawnIcon(for icon: Icon, metrics: Metrics) -> DrawnIcon {
        let box = NSSize(width: metrics.iconSize, height: metrics.iconSize)
        switch icon {
        case .image(let image):
            return DrawnIcon(image: image, size: box, isSymbol: false)
        case .symbol(let symbol):
            // `withSymbolConfiguration(_:)` replaces the configuration rather than adding to it, so
            // the style's is applied over the symbol's first.
            guard let configuration = metrics.symbolConfiguration,
                  let configuredSymbol = symbol.withSymbolConfiguration(symbol.symbolConfiguration.applying(configuration))
            else {
                return DrawnIcon(image: symbol, size: box, isSymbol: true)
            }
            return DrawnIcon(image: configuredSymbol, size: configuredSymbol.size, isSymbol: true)
        }
    }

    /// Whether the popover the picker opened is on screen. The highlight stays while it is, as Xcode
    /// keeps drawing the presenting component as hovered.
    public var isShowingPopover = false {
        didSet {
            guard isShowingPopover != oldValue else { return }
            needsDisplay = true
            changeHandler?(.popover)
        }
    }

    /// Whether the pointer is over the picker.
    public private(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            changeHandler?(.hover)
        }
    }

    /// Told of every `Change`, for the owner that lays the picker out.
    var changeHandler: ((Change) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    private var windowObservers: [NSObjectProtocol] = []

    public init(style: Style) {
        self.style = style
        switch style {
        case .activityView:
            metrics = .activityView(usesGlassMetrics: ToolbarActivityView.usesGlassToolbarMetrics)
        case .toolbar:
            metrics = .toolbar
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: metrics.height))
        focusRingType = .none
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool {
        true
    }

    public override var acceptsFirstResponder: Bool {
        false
    }

    public override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    // MARK: - Size

    /// The component's width at full size: insets, icon, spacing and the title's natural width — the
    /// width of DVTKit's `cellSizeForBounds:`, not rounded.
    public var componentWidth: CGFloat {
        let iconWidth: CGFloat = drawnIcon?.size.width ?? 0
        let titleWidth = title.isEmpty ? 0 : titleSize.width + (drawnIcon == nil ? 0 : Self.iconTitleSpacing)
        return metrics.leadingInset + iconWidth + titleWidth + metrics.trailingInset
    }

    /// The icon slot's size, which counts in places even without an icon: DVTKit's `_iconSize`.
    private var iconSlotSize: NSSize {
        drawnIcon?.size ?? NSSize(width: metrics.iconSize, height: metrics.iconSize)
    }

    /// The width that shows the component whole — DVTKit's `sizeWanted`.
    public var wantedWidth: CGFloat {
        componentWidth + Self.wantedWidthAllowance
    }

    /// Whether the picker shows its title whole at its current width: DVTKit compares the drawn
    /// width with the component's width rounded up.
    var showsWholeComponent: Bool {
        bounds.width >= componentWidth.rounded(.up)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: wantedWidth.rounded(.up), height: metrics.height)
    }

    private var titleSize: NSSize {
        attributedTitle(color: .labelColor).size()
    }

    private func wantedWidthDidChange() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
        changeHandler?(.wantedWidth)
    }

    // MARK: - Layout of the content

    /// Where the title goes in a picker `width` points wide, and whether it fades: DVTKit's
    /// `drawInteriorWithFrame:inView:`. `nil` when the component has no room for a title.
    func titleLayout(forWidth width: CGFloat) -> (rect: NSRect, fades: Bool)? {
        guard !title.isEmpty else { return nil }
        let textOffset = metrics.leadingInset + (drawnIcon.map { $0.size.width + Self.iconTitleSpacing } ?? 0)
        guard width - (textOffset + metrics.trailingInset) > Self.minimumTitleRoom else { return nil }
        let size = titleSize
        let availableWidth = width - (textOffset + metrics.trailingInset - Self.wantedWidthAllowance)
        let scale = backingScaleFactor
        let y = ((bounds.midY - size.height / 2) * scale).rounded(.down) / scale
        let fades = size.width - availableWidth > Self.titleFadeThreshold
        return (NSRect(x: textOffset, y: y, width: min(size.width, availableWidth), height: size.height), fades)
    }

    /// The icon's slot: in from the leading edge by the leading inset, centred on the pixel grid.
    var iconRect: NSRect {
        let size = iconSlotSize
        let scale = backingScaleFactor
        let y = ((bounds.height - size.height) / 2 * scale).rounded(.down) / scale
        return NSRect(x: metrics.leadingInset, y: y, width: size.width, height: size.height)
    }

    /// The highlight across the picker: DVTKit's `_drawHoveredInFrame:` for the only component.
    var highlightRect: NSRect {
        let scale = backingScaleFactor
        var rect = NSRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, metrics.highlightHeight))
        if bounds.height > rect.height {
            rect.origin.y = ((bounds.midY - rect.height / 2) * scale).rounded(.down) / scale
        }
        rect.origin.x += metrics.highlightLeadingInset
        rect.size.width -= metrics.highlightLeadingInset
        return rect.insetBy(dx: 0, dy: metrics.highlightVerticalInset)
    }

    /// Whether the picker draws its highlight now.
    var drawsHighlight: Bool {
        isHovered || isShowingPopover
    }

    private var backingScaleFactor: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let isActive = drawsActive
        if drawsHighlight {
            if metrics.showsHoverChevron {
                drawChevron(isActive: isActive)
            }
            let highlightRect = highlightRect
            let radius = metrics.drawsCapsuleHighlight ? highlightRect.height / 2 : 4
            Self.highlightColor.setFill()
            NSBezierPath(roundedRect: highlightRect, xRadius: radius, yRadius: radius).fill()
        }
        if let drawnIcon {
            drawIcon(drawnIcon, isActive: isActive)
        }
        drawTitle()
    }

    /// Whether the picker draws as in a window with the active appearance: the window is key and
    /// the picker enabled. Otherwise the icon dims to half and the title goes paler.
    private var drawsActive: Bool {
        isEnabled && (window?.isKeyWindow ?? true)
    }

    private var titleColor: NSColor {
        if window?.isKeyWindow ?? true {
            return isEnabled ? .labelColor : .secondaryLabelColor
        }
        return Self.isDark(effectiveAppearance) && isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
    }

    private func attributedTitle(color: NSColor) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byClipping
        return NSAttributedString(string: title, attributes: [
            .font: metrics.font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle,
        ])
    }

    private func drawTitle() {
        guard let layout = titleLayout(forWidth: bounds.width), let context = NSGraphicsContext.current else { return }
        let title = attributedTitle(color: titleColor)
        guard layout.fades else {
            title.draw(at: layout.rect.origin)
            return
        }
        context.saveGraphicsState()
        context.cgContext.beginTransparencyLayer(in: layout.rect, auxiliaryInfo: nil)
        NSBezierPath(rect: layout.rect).addClip()
        title.draw(at: layout.rect.origin)
        let fadeRect = NSRect(x: layout.rect.maxX - Self.titleFadeWidth, y: layout.rect.minY, width: Self.titleFadeWidth, height: layout.rect.height)
        context.cgContext.setBlendMode(.destinationIn)
        NSGradient(starting: .black, ending: .clear)?.draw(in: fadeRect, angle: 0)
        context.cgContext.endTransparencyLayer()
        context.restoreGraphicsState()
    }

    private func drawIcon(_ drawnIcon: DrawnIcon, isActive: Bool) {
        let image = drawnIcon.image
        let box = iconRect
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let drawnSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawnRect = NSRect(
            x: box.midX - drawnSize.width / 2,
            y: box.midY - drawnSize.height / 2,
            width: drawnSize.width,
            height: drawnSize.height
        )
        let fraction: CGFloat = isActive ? 1 : 0.5
        let drawnImage = image.isTemplate && !drawnIcon.isSymbol ? Self.tinted(image, with: titleColor) : image
        drawnImage.draw(in: drawnRect, from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true, hints: nil)
    }

    /// Xcode 26's down chevron while hovered: `chevron.down` at 8 points, medium, or bold when the
    /// picker is not active, centred in the trailing inset less 3 in a capsule, and drawn only where
    /// it clears the icon.
    private func drawChevron(isActive: Bool) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: isActive ? .medium : .bold)
        guard let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let areaWidth = metrics.trailingInset - (metrics.drawsCapsuleHighlight ? Self.chevronTrailingMargin : 0)
        let area = NSRect(x: bounds.maxX - metrics.trailingInset, y: 0, width: areaWidth, height: bounds.height)
        let chevronRect = NSRect(
            x: area.midX - chevron.size.width / 2,
            y: area.midY - chevron.size.height / 2,
            width: chevron.size.width,
            height: chevron.size.height
        )
        guard chevronRect.minX > bounds.minX + metrics.leadingInset + iconSlotSize.width else { return }
        let tint: NSColor = if Self.isDark(effectiveAppearance) {
            isActive ? .labelColor : .secondaryLabelColor
        } else {
            isActive ? .labelColor : .tertiaryLabelColor
        }
        Self.tinted(chevron, with: tint).draw(in: chevronRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private static func tinted(_ image: NSImage, with color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    nonisolated static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: - Pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag, .inVisibleRect]
        let pointerLocation = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        if let pointerLocation, bounds.contains(pointerLocation) {
            options.insert(.assumeInside)
        }
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    public override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    /// The press sends the action at once — DVTKit opens the popover on mouse-down — and nothing
    /// follows: the popover the action shows tracks the button itself.
    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }

    public override func rightMouseDown(with event: NSEvent) {
        mouseDown(with: event)
    }

    // MARK: - Window

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
        guard let newWindow else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.needsDisplay = true
                }
            })
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Accessibility

    /// A pop-up button named for what it chooses, as Xcode names its scheme component "Active Scheme".
    public override func isAccessibilityElement() -> Bool {
        true
    }

    public override func accessibilityRole() -> NSAccessibility.Role? {
        .popUpButton
    }

    public override func accessibilityLabel() -> String? {
        "Runtime Source"
    }

    public override func accessibilityValue() -> Any? {
        title
    }

    public override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        return sendAction(action, to: target)
    }

    public override func accessibilityPerformShowMenu() -> Bool {
        accessibilityPerformPress()
    }
}

#endif
