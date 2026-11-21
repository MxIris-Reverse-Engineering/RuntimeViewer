import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication

/// A row of the start page — a recent object or a match of its Open Quickly field — and of the
/// File › Open Quickly… bar, as Xcode's initial editor draws a recent file: the item's icon in a
/// 32-point slot, and beside it its name and, under the name, its path — the first component's
/// icon, then the components joined with a compact chevron — over a hairline that starts under
/// the text.
final class ContentStartPageItemCellView: TableCellView {
    private let iconView = ImageView().then {
        $0.imageScaling = .scaleNone
        $0.imageAlignment = .alignCenter
    }

    private let titleLabel = Label().then {
        $0.font = .systemFont(ofSize: Metrics.titleFontSize, weight: .regular)
        $0.textColor = .labelColor
        $0.lineBreakMode = .byTruncatingMiddle
        $0.maximumNumberOfLines = 1
    }

    private let pathIconView = ImageView()

    private let pathLabel = Label().then {
        $0.font = .systemFont(ofSize: Metrics.pathFontSize, weight: .regular)
        $0.textColor = .secondaryLabelColor
        $0.lineBreakMode = .byTruncatingMiddle
        $0.maximumNumberOfLines = 1
    }

    private let separatorView = HorizontalSeparatorView()

    /// Whether a hairline runs under the row's text: the recent objects have one, the search
    /// results none.
    var showsSeparator = true {
        didSet { separatorView.isHidden = !showsSeparator }
    }

    /// How far the icon and the hairline keep from the row's ends.
    var contentHorizontalInset: CGFloat = 0 {
        didSet {
            guard contentHorizontalInset != oldValue else { return }
            iconLeadingConstraint?.update(inset: contentHorizontalInset)
            separatorTrailingConstraint?.update(inset: contentHorizontalInset)
        }
    }

    private var iconLeadingConstraint: Constraint?

    private var separatorTrailingConstraint: Constraint?

    override func setup() {
        super.setup()

        let pathStackView = HStackView(alignment: .top, spacing: Metrics.pathIconToTextSpacing) {
            pathIconView
            pathLabel
        }

        let textStackView = VStackView(alignment: .leading, spacing: 1) {
            titleLabel
            pathStackView
        }

        hierarchy {
            iconView
            textStackView
            separatorView
        }

        // The icon's top lines up with the text's, as in Xcode's row, and the two together sit
        // in the middle of the row, whatever its height.
        iconView.snp.makeConstraints { make in
            iconLeadingConstraint = make.leading.equalToSuperview().inset(contentHorizontalInset).constraint
            make.top.equalTo(textStackView)
            make.centerY.equalToSuperview().priority(.low)
            make.top.greaterThanOrEqualToSuperview()
            make.size.equalTo(Metrics.iconSlotSide)
        }

        pathIconView.snp.makeConstraints { make in
            make.width.equalTo(Metrics.pathIconSide)
            make.height.equalTo(Metrics.pathIconFrameHeight)
        }

        textStackView.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(Metrics.iconToTextSpacing)
            make.trailing.lessThanOrEqualToSuperview().inset(Metrics.rowTrailingInset)
        }

        separatorView.snp.makeConstraints { make in
            make.leading.equalTo(textStackView)
            separatorTrailingConstraint = make.trailing.equalToSuperview().inset(contentHorizontalInset).constraint
            make.bottom.equalToSuperview()
        }
    }

    func configure(with cellViewModel: ContentStartPageItemCellViewModel) {
        let appearance = cellViewModel.appearance
        iconView.image = appearance.icon.image(size: ContentStartPageItemCellViewModel.iconSize)
        titleLabel.stringValue = appearance.title
        pathIconView.image = appearance.pathIcon?.image(size: Metrics.pathIconSide)
        pathIconView.isHidden = appearance.pathIcon == nil
        pathLabel.attributedStringValue = Self.pathText(joining: appearance.pathComponents)
    }

    /// The path's components with Xcode's separator between each two: a space, SF Symbols'
    /// `chevron.compact.right` at the line's size and colour, and a space.
    private static func pathText(joining pathComponents: [String]) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Metrics.pathFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let pathText = NSMutableAttributedString()
        for (componentIndex, component) in pathComponents.enumerated() {
            if componentIndex > 0 {
                pathText.append(NSAttributedString(string: " ", attributes: attributes))
                pathText.append(chevron(attributes: attributes))
                pathText.append(NSAttributedString(string: " ", attributes: attributes))
            }
            pathText.append(NSAttributedString(string: component, attributes: attributes))
        }
        return pathText
    }

    private static func chevron(attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.pathFontSize, weight: .regular)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        guard let image = NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return NSAttributedString(string: "›", attributes: attributes) }
        let attachment = NSTextAttachment()
        attachment.image = image
        let chevron = NSMutableAttributedString(attachment: attachment)
        chevron.addAttributes(attributes, range: NSRange(location: 0, length: chevron.length))
        return chevron
    }
}

extension ContentStartPageItemCellView {
    /// The row's measurements: Xcode 27.2's `RecentItemView` and `ItemPathView` in IDEKit (the
    /// proposal `editor-start-page` lists the addresses).
    fileprivate enum Metrics {
        /// The square Xcode's row lays its icon out in (`IconView` with a 32 × 32 layout size); the
        /// object's glyph is drawn smaller inside it, at `ContentStartPageItemCellViewModel.iconSize`.
        static let iconSlotSide: CGFloat = 32
        static let iconToTextSpacing: CGFloat = 4
        static let rowTrailingInset: CGFloat = 4
        static let titleFontSize: CGFloat = 13
        static let pathFontSize: CGFloat = 11
        static let pathIconSide: CGFloat = 12
        static let pathIconFrameHeight: CGFloat = 14
        static let pathIconToTextSpacing: CGFloat = 2
    }
}
