#if os(macOS)

import AppKit

/// A toolbar item showing a title, an optional subtitle below it and an optional image beside
/// them, for a window that hides its own title.
///
/// A text too long for the toolbar is cut short with an ellipsis; it never pushes the items after
/// it into the overflow menu. Getting there takes four settings that only work together, because
/// NSToolbar does not size an item from its view's frame: it solves the view in a layout engine of
/// its own, once pulled to zero width at priority 200 for the minimum width and once to 10,000
/// points at priority 200 for the maximum (`-[NSToolbarItem _itemViewMinSize:maxSize:stretchesContent:]`,
/// the same on macOS 26.6 and 27.0), and it moves items into the overflow menu by their minimum
/// widths alone. Each setting below says what breaks without it, and
/// `TitleToolbarItemOverflowTests` fails if any of them goes. Background:
/// `Documentations/ResolvedIssues/2026-10-02-long-toolbar-title-pushed-items-into-overflow.md`.
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

    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let textStackView = NSStackView()
    private let containerStackView = NSStackView()

    /// The narrowest the item gets: its insets and the ellipsis a truncated title ends with.
    ///
    /// It also keeps the measured minimum width above zero, which the toolbar needs. A measured
    /// minimum width of exactly 0 is taken to mean the view could not be measured: the toolbar logs
    /// "view was automatically measured but had an ambiguous height or width" and falls back to the
    /// view's current frame for both the minimum and the maximum width, so a view it has not laid
    /// out yet stays zero points wide. With compressible labels the measurement does come out at 0 —
    /// the stack view's 8-point inset did not hold it open — and before the labels were compressible
    /// it already did once, while the title was still empty.
    private lazy var minimumWidthConstraint = containerStackView.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)

    /// The widest the item gets: its insets and the wider label at full width, at a priority above
    /// 200 so that the maximum-width measurement stops there. With the text stack hugging its labels
    /// below 200, nothing else does: the item would stretch over all the room the other items leave.
    private lazy var maximumWidthConstraint = containerStackView.widthAnchor.constraint(lessThanOrEqualToConstant: 0)

    public var displayTitle: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            updateWidthLimits()
        }
    }

    public var displaySubtitle: String {
        get { subtitleLabel.stringValue }
        set {
            let hadSubtitle = !subtitleLabel.stringValue.isEmpty
            let hasSubtitle = !newValue.isEmpty
            subtitleLabel.stringValue = newValue
            subtitleLabel.isHidden = newValue.isEmpty
            if hadSubtitle != hasSubtitle {
                updateTitleFont()
            }
            updateWidthLimits()
        }
    }

    public var displayImage: NSImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            imageView.isHidden = newValue == nil
            updateWidthLimits()
        }
    }

    public var insets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0) {
        didSet {
            containerStackView.edgeInsets = insets
            updateWidthLimits()
        }
    }

    public override init(itemIdentifier: NSToolbarItem.Identifier) {
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

        containerStackView.setViews([imageView, textStackView], in: .center)
        containerStackView.orientation = .horizontal
        containerStackView.alignment = .centerY
        containerStackView.spacing = 10
        containerStackView.edgeInsets = insets

        maximumWidthConstraint.priority = .defaultLow
        NSLayoutConstraint.activate([minimumWidthConstraint, maximumWidthConstraint])

        updateTitleFont()
        updateWidthLimits()

        view = containerStackView
    }

    private func updateTitleFont() {
        let hasSubtitle = !subtitleLabel.isHidden
        if hasSubtitle {
            titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        } else {
            titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        }
    }

    private func updateWidthLimits() {
        let ellipsisLabel = NSTextField(labelWithString: "\u{2026}")
        ellipsisLabel.font = titleLabel.font
        let insetsWidth = insets.left + insets.right
        let imageWidth = imageView.isHidden ? 0 : imageView.intrinsicContentSize.width + containerStackView.spacing
        let subtitleWidth = subtitleLabel.isHidden ? 0 : subtitleLabel.intrinsicContentSize.width
        minimumWidthConstraint.constant = insetsWidth + imageWidth + ellipsisLabel.intrinsicContentSize.width
        maximumWidthConstraint.constant = insetsWidth + imageWidth + max(titleLabel.intrinsicContentSize.width, subtitleWidth)
    }
}

#endif
