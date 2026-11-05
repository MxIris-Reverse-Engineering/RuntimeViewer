#if os(macOS)

import AppKit

/// A toolbar item showing a title, an optional subtitle below it and an optional image beside
/// them, for a window that hides its own title.
///
/// A text too long for the toolbar is cut short with an ellipsis: it never pushes the items after
/// it into the overflow menu, nor the toolbar's centered item aside. NSToolbar does not size an item
/// from its view's frame: it solves the view in a layout engine of its own, once pulled to zero width
/// at priority 200 for the minimum width and once to 10,000 points at priority 200 for the maximum
/// (`-[NSToolbarItem _itemViewMinSize:maxSize:stretchesContent:]`, the same on macOS 26.6 and 27.0); it
/// moves items into the overflow menu by their minimum widths alone; and in a section with a centered
/// item it shares the room left over among the items before that item, the item and the items after
/// it, each group up to its widest, before it places the centered item
/// (`-[NSBarLayout _centerRectGivenItems:leadingItems:trailingItems:inRect:]`, the same on macOS 27.0 and
/// 27.2). So the item's view (`ItemView`) has no widest of its own — the toolbar counts a view that
/// measures 10,000 points wide at its minimum there — and takes whatever room the toolbar gives it,
/// and the title sits at its leading edge in a container that takes four settings that only work
/// together. Each setting below says what breaks without it, and `TitleToolbarItemOverflowTests` and
/// `ToolbarCenteredItemTests` fail if any of them goes. Background:
/// `Documentations/ResolvedIssues/2026-10-02-long-toolbar-title-pushed-items-into-overflow.md` and
/// `Documentations/ResolvedIssues/2026-11-05-long-toolbar-title-pushed-the-centered-item-aside.md`.
///
/// Made with `showsActivity`, the item is Xcode 27's window title (IDEKit 27.2
/// `IDEActivityWindowTitleView`): an 18-point slot left of the text shows the document's icon, and
/// the activity's progress in its place (`TitleActivityIndicatorView`); the title is always 13-point
/// bold; both lines blend with what is behind them and go to the tertiary colour in a window that is
/// not key; and while the pointer is over the item the subtitle shows the activity's text instead of
/// its own. Spec: `/Volumes/RE/Xcode/27.2-27B52/README.md`, "Activity progress in the window title".
public final class TitleToolbarItem: NSToolbarItem {
    /// The labels' horizontal compression resistance: below 200, so that the minimum-width
    /// measurement can squeeze them. At `.defaultLow` (250) the whole text became the item's
    /// minimum width and a long title pushed every item after it into the overflow menu.
    private static let labelCompressionResistance = NSLayoutConstraint.Priority(199)

    /// The text stack's horizontal hugging: below `labelCompressionResistance`. A vertical stack
    /// view pulls the trailing edge of every label it holds towards its own at this priority, so
    /// at the default 250 it squeezed the wider label down to the narrower one — measured, a long
    /// title came out as wide as the subtitle "NSControl" with hundreds of points to spare.
    private static let textStackHuggingPriority = NSLayoutConstraint.Priority(198)

    /// How hard the title's container is pulled out to the item's width, so that it is as wide as it
    /// was while it was the item's view itself: up to its own widest, `maximumWidthConstraint`, which
    /// outranks the pull. Below 200, the priority at which the toolbar pulls the item's view when it
    /// measures the item: at 200 or more the pull would hold the item's view to the container's width
    /// and give the item a widest again.
    private static let containerFillPriority = NSLayoutConstraint.Priority(150)

    /// Xcode 27's `.padding(.horizontal, 10)` around the icon slot and the text.
    private static let activityHorizontalPadding: CGFloat = 10

    /// Between the icon slot and the text: the default spacing of a SwiftUI `HStack` between an
    /// image and text on macOS, which Xcode 27 leaves unset. Not measured against Xcode.
    private static let activityIconSpacing: CGFloat = 8

    /// While the pointer stays over the item, the activity text widens the title's container in
    /// steps of this, and never narrows it, so that a text that changes every second does not move
    /// the container's edge under the pointer — Xcode's `resizeIncrement` for its title item.
    private static let activityWidthIncrement: CGFloat = 20

    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let textStackView = NSStackView()
    private let containerStackView = ContainerStackView()

    /// The item's view, which holds `containerStackView` at its leading edge.
    private let itemView = ItemView()

    /// The window title's activity display, when the item was made with `showsActivity`: it takes
    /// the image's place. A click on it sends its action.
    public let activityIndicator: TitleActivityIndicatorView?

    /// The narrowest the title's container, and so the item, gets: its insets and the ellipsis a
    /// truncated title ends with.
    ///
    /// It also keeps the measured minimum width above zero, which the toolbar needs. A measured
    /// minimum width of exactly 0 is taken to mean the view could not be measured: the toolbar logs
    /// "view was automatically measured but had an ambiguous height or width" and falls back to the
    /// view's current frame for both the minimum and the maximum width, so a view it has not laid
    /// out yet stays zero points wide. With compressible labels the measurement does come out at 0 —
    /// the stack view's 8-point inset did not hold it open — and before the labels were compressible
    /// it already did once, while the title was still empty.
    private lazy var minimumWidthConstraint = containerStackView.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)

    /// The widest the title's container gets: its insets and the wider label at full width, at a
    /// priority above `containerFillPriority`, so that the pull out to the item's width stops there.
    /// With the text stack hugging its labels below 200, nothing else does: the container would
    /// stretch over all the room the toolbar gives the item, and take the pointer over all of it.
    private lazy var maximumWidthConstraint = containerStackView.widthAnchor.constraint(lessThanOrEqualToConstant: 0)

    /// The subtitle the owner sets; the activity text stands in for it while the pointer is over
    /// an item that shows activity.
    private var ownSubtitle = ""

    /// The text of the activity on show, for the subtitle while the pointer is over the item.
    private var activityText: String?

    /// The activity whose text the subtitle shows, so a new one may narrow the item again.
    private var activityReportIdentifier: UUID?

    private var isPointerInside = false

    /// The widest the item has been while the pointer stays over it; 0 otherwise.
    private var hoverMaximumWidth: CGFloat = 0

    public var displayTitle: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            updateWidthLimits()
        }
    }

    /// The subtitle as it shows now: the owner's, or the activity's text.
    var shownSubtitle: String {
        subtitleLabel.isHidden ? "" : subtitleLabel.stringValue
    }

    public var displaySubtitle: String {
        get { ownSubtitle }
        set {
            ownSubtitle = newValue
            updateSubtitle(animated: false)
        }
    }

    public var displayImage: NSImage? {
        get { activityIndicator?.icon ?? imageView.image }
        set {
            if let activityIndicator {
                activityIndicator.icon = newValue
            } else {
                imageView.image = newValue
                imageView.isHidden = newValue == nil
            }
            updateWidthLimits()
        }
    }

    public var insets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0) {
        didSet {
            containerStackView.edgeInsets = insets
            updateWidthLimits()
        }
    }

    public convenience override init(itemIdentifier: NSToolbarItem.Identifier) {
        self.init(itemIdentifier: itemIdentifier, showsActivity: false)
    }

    public init(itemIdentifier: NSToolbarItem.Identifier, showsActivity: Bool) {
        activityIndicator = showsActivity ? TitleActivityIndicatorView() : nil
        super.init(itemIdentifier: itemIdentifier)
        isNavigational = true
        isBordered = false

        imageView.imageScaling = .scaleProportionallyDown
        imageView.isHidden = true
        imageView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .left
        titleLabel.setContentCompressionResistancePriority(Self.labelCompressionResistance, for: .horizontal)

        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.alignment = .left
        subtitleLabel.isHidden = true
        subtitleLabel.setContentCompressionResistancePriority(Self.labelCompressionResistance, for: .horizontal)

        textStackView.setViews([titleLabel, subtitleLabel], in: .center)
        textStackView.orientation = .vertical
        textStackView.alignment = .leading
        textStackView.spacing = 0
        textStackView.setHuggingPriority(Self.textStackHuggingPriority, for: .horizontal)

        containerStackView.orientation = .horizontal
        containerStackView.alignment = .centerY

        if let activityIndicator {
            // `.subheadline.monospacedDigit()`, middle truncation, as Xcode's subtitle.
            subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            subtitleLabel.lineBreakMode = .byTruncatingMiddle
            textStackView.wantsLayer = true
            containerStackView.setViews([activityIndicator, textStackView], in: .center)
            containerStackView.spacing = Self.activityIconSpacing
            insets = NSEdgeInsets(top: 0, left: Self.activityHorizontalPadding, bottom: 0, right: Self.activityHorizontalPadding)
            containerStackView.pointerInsideDidChange = { [weak self] isInside in
                guard let self else { return }
                isPointerInside = isInside
                if !isInside {
                    hoverMaximumWidth = 0
                }
                updateSubtitle(animated: true)
            }
            containerStackView.windowStateDidChange = { [weak self] in
                guard let self else { return }
                updateActivityTextAppearance()
            }
        } else {
            containerStackView.setViews([imageView, textStackView], in: .center)
            containerStackView.spacing = 10
        }
        containerStackView.edgeInsets = insets

        maximumWidthConstraint.priority = .defaultLow
        NSLayoutConstraint.activate([minimumWidthConstraint, maximumWidthConstraint])

        itemView.hierarchy {
            containerStackView
        }

        containerStackView.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.trailing.lessThanOrEqualToSuperview()
            make.width.equalToSuperview().priority(Self.containerFillPriority.rawValue)
        }

        updateTitleFont()
        updateActivityTextAppearance()
        updateWidthLimits()

        view = itemView
    }

    /// Shows the activity `state` shows: its progress in the icon slot, and its text for the
    /// subtitle while the pointer is over the item. Does nothing for an item without activity.
    public func applyActivity(_ state: ToolbarActivityState, animated: Bool) {
        guard let activityIndicator else { return }
        activityIndicator.apply(state, animated: animated)
        if state.reportIdentifier != activityReportIdentifier {
            activityReportIdentifier = state.reportIdentifier
            hoverMaximumWidth = 0
        }
        let newActivityText = state.reportIdentifier == nil ? nil : state.segments.plainText(primarySeparator: " \u{2022} ")
        guard newActivityText != activityText else { return }
        activityText = newActivityText
        updateSubtitle(animated: animated)
    }

    /// The owner's subtitle, or the activity's text while the pointer is over an item showing
    /// activity — faded in and out as Xcode's subtitle is (it adds a one-point blur too).
    private func updateSubtitle(animated: Bool) {
        let shownText = (isPointerInside ? activityText : nil) ?? ownSubtitle
        let hadSubtitle = !subtitleLabel.isHidden
        let hasSubtitle = !shownText.isEmpty
        if animated, subtitleLabel.stringValue != shownText, let layer = textStackView.layer {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = hasSubtitle ? 0.25 : 0.5
            layer.add(transition, forKey: "subtitle")
        }
        subtitleLabel.stringValue = shownText
        subtitleLabel.isHidden = !hasSubtitle
        if hadSubtitle != hasSubtitle {
            updateTitleFont()
        }
        updateWidthLimits()
    }

    private func updateTitleFont() {
        if activityIndicator != nil {
            // `.body.weight(.bold)`, with or without a subtitle.
            titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .bold)
            return
        }
        let hasSubtitle = !subtitleLabel.isHidden
        if hasSubtitle {
            titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        } else {
            titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        }
    }

    /// Xcode 27's text colours — primary and secondary in the key window, tertiary otherwise — and
    /// its blending, plus-darker in a light appearance and plus-lighter in a dark one, through Core
    /// Animation's private compositing filters.
    private func updateActivityTextAppearance() {
        guard activityIndicator != nil else { return }
        let isKey = containerStackView.window?.isKeyWindow ?? true
        titleLabel.textColor = isKey ? .labelColor : .tertiaryLabelColor
        subtitleLabel.textColor = isKey ? .secondaryLabelColor : .tertiaryLabelColor
        textStackView.layer?.compositingFilter = containerStackView.effectiveAppearance.vibrancyCompositingFilter
    }

    private func updateWidthLimits() {
        let ellipsisLabel = NSTextField(labelWithString: "\u{2026}")
        ellipsisLabel.font = titleLabel.font
        let insetsWidth = insets.left + insets.right
        let leadingWidth: CGFloat
        if let activityIndicator {
            leadingWidth = activityIndicator.intrinsicContentSize.width + containerStackView.spacing
        } else {
            leadingWidth = imageView.isHidden ? 0 : imageView.intrinsicContentSize.width + containerStackView.spacing
        }
        let subtitleWidth = subtitleLabel.isHidden ? 0 : subtitleLabel.intrinsicContentSize.width
        minimumWidthConstraint.constant = insetsWidth + leadingWidth + ellipsisLabel.intrinsicContentSize.width
        var maximumWidth = insetsWidth + leadingWidth + max(titleLabel.intrinsicContentSize.width, subtitleWidth)
        if activityIndicator != nil, isPointerInside, activityText != nil {
            maximumWidth = max((maximumWidth / Self.activityWidthIncrement).rounded(.up) * Self.activityWidthIncrement, hoverMaximumWidth)
            hoverMaximumWidth = maximumWidth
        }
        maximumWidthConstraint.constant = maximumWidth
    }
}

extension TitleToolbarItem {
    /// The item's view: as wide as the toolbar lays the item out, with the title's container at its
    /// leading edge.
    ///
    /// It has no widest of its own, so the toolbar measures the item 10,000 points wide at most and
    /// counts it at its minimum width when it decides where the centered item goes: the centered item
    /// stays where it is, and the title gets the room left beside it. Only the container hugs the
    /// text. The rest of this view takes no clicks, so that a click there goes to the toolbar behind
    /// it, as one on the flexible space that this room used to go to does.
    private final class ItemView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hitView = super.hitTest(point)
            return hitView === self ? nil : hitView
        }
    }

    /// The title's container: tells the item where the pointer is and when the window changes.
    private final class ContainerStackView: NSStackView {
        var pointerInsideDidChange: ((Bool) -> Void)?

        var windowStateDidChange: (() -> Void)?

        private var trackingArea: NSTrackingArea?

        private var windowObservations: [NSObjectProtocol] = []

        deinit {
            windowObservations.forEach(NotificationCenter.default.removeObserver)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard pointerInsideDidChange != nil else { return }
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let newTrackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(newTrackingArea)
            trackingArea = newTrackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            pointerInsideDidChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            pointerInsideDidChange?(false)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            windowObservations.forEach(NotificationCenter.default.removeObserver)
            windowObservations = []
            guard let newWindow, windowStateDidChange != nil else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                windowObservations.append(NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.windowStateDidChange?()
                    }
                })
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowStateDidChange?()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            windowStateDidChange?()
        }
    }
}

#endif
