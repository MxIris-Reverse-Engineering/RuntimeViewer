#if os(macOS)

import AppKit
import SnapKit
import UIFoundation

/// A row of the runtime source picker's popover: Xcode 27.2's `ActivityViewPopoverTableCellView`, the
/// row the scheme picker's popover gives each scheme — a checkmark, an icon and a title.
///
/// From the cell's leading edge, which the popover puts 25 points in from the row's (14 before the
/// macOS 26 design): the checkmark in a 12-point box, the 16-point icon 2 points after it, the 13-point
/// title 6 points after that, cut short at its tail. The checkmark's box stays when the row is not
/// checked, so every icon lines up; the icon's box stays without an icon too. A disabled row has its
/// title in the secondary label colour.
///
/// While the popover filters, the characters that matched are bold in the text colour and the rest go
/// to the secondary label colour; on a selected row both turn to the selected text colour, the rest at
/// three quarters — Xcode's `DVTFilterMatchFormatter`. Spec: `/Volumes/RE/Xcode/27.2-27B52/README.md`,
/// "The scheme picker's popover", §3.
public final class RuntimeSourcePopoverCellView: TableCellView {
    static let checkmarkSize: CGFloat = 12

    static let iconSize: CGFloat = 16

    static let checkmarkIconSpacing: CGFloat = 2

    static let iconTitleSpacing: CGFloat = 6

    static let titleFontSize = NSFont.systemFontSize

    /// The selected text colour at three quarters, for the characters that did not match on a selected
    /// row — `selectedFilterResultNonMatchingTextColor`.
    static let selectedNonMatchingAlpha: CGFloat = 0.75

    private let checkmarkView = NSImageView()

    private let iconView = NSImageView()

    private let titleField = NSTextField(labelWithString: "")

    /// The row's title.
    public var title: String = "" {
        didSet {
            guard title != oldValue else { return }
            updateTitle()
        }
    }

    public var icon: NSImage? {
        get { iconView.image }
        set { iconView.image = newValue }
    }

    /// Whether the row carries the checkmark: the source the window is on.
    public var isChecked = false {
        didSet { checkmarkView.isHidden = !isChecked }
    }

    /// Whether the row can be chosen; a disabled one has its title in the secondary label colour.
    public var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            updateTitle()
        }
    }

    /// The ranges of the title the filter matched, bold while the popover filters; empty otherwise.
    public var filterMatchRanges: [NSRange] = [] {
        didSet {
            guard filterMatchRanges != oldValue else { return }
            updateTitle()
        }
    }

    public override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            checkmarkView.cell?.backgroundStyle = backgroundStyle
            updateTitle()
        }
    }

    /// The title as the row shows it, with the filter's emphasis.
    var displayedTitle: NSAttributedString {
        titleField.attributedStringValue
    }

    /// The frames of the checkmark's, the icon's and the title's boxes, after layout.
    var checkmarkFrame: NSRect { checkmarkView.frame }

    var iconFrame: NSRect { iconView.frame }

    var titleFrame: NSRect { titleField.frame }

    public override func setup() {
        super.setup()
        let checkmarkConfiguration = NSImage.SymbolConfiguration(pointSize: 0, weight: .semibold, scale: .small)
        checkmarkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Current")?
            .withSymbolConfiguration(checkmarkConfiguration)
        checkmarkView.isHidden = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.titleFontSize, weight: .regular)

        titleField.font = .systemFont(ofSize: Self.titleFontSize)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.allowsExpansionToolTips = true
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textField = titleField
        imageView = iconView

        hierarchy {
            checkmarkView
            iconView
            titleField
        }
        checkmarkView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalToSuperview()
            make.size.equalTo(Self.checkmarkSize)
        }
        iconView.snp.makeConstraints { make in
            make.leading.equalTo(checkmarkView.snp.trailing).offset(Self.checkmarkIconSpacing)
            make.centerY.equalToSuperview()
            make.size.equalTo(Self.iconSize)
        }
        titleField.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(Self.iconTitleSpacing)
            make.trailing.lessThanOrEqualToSuperview()
            make.centerY.equalToSuperview()
        }
        updateTitle()
    }

    private func updateTitle() {
        let baseColor: NSColor = isEnabled ? .labelColor : .secondaryLabelColor
        let font = NSFont.systemFont(ofSize: Self.titleFontSize)
        guard !filterMatchRanges.isEmpty else {
            titleField.textColor = baseColor
            titleField.stringValue = title
            return
        }
        let isEmphasized = backgroundStyle == .emphasized
        let nonMatchingColor: NSColor = isEmphasized
            ? .alternateSelectedControlTextColor.withAlphaComponent(Self.selectedNonMatchingAlpha)
            : .secondaryLabelColor
        let matchingColor: NSColor = isEmphasized ? .alternateSelectedControlTextColor : .textColor
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        let attributedTitle = NSMutableAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: nonMatchingColor,
            .paragraphStyle: paragraphStyle,
        ])
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let titleLength = (title as NSString).length
        for range in filterMatchRanges where range.location != NSNotFound && NSMaxRange(range) <= titleLength {
            attributedTitle.addAttributes([.font: boldFont, .foregroundColor: matchingColor], range: range)
        }
        titleField.attributedStringValue = attributedTitle
    }
}

#endif
