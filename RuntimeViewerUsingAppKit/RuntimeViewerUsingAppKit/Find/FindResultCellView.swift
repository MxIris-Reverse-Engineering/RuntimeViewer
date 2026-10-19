import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import SnapKit

/// A row of the Find navigator's outline: Xcode's `IDEFindNavigatorTableCellView` — the icon
/// (`FindResultCellStyle.Metrics.iconSize`, 16 points in Xcode) at the leading edge, the title 3 points
/// after it, both 3 points down; a hit's line wraps onto a second line, which makes the row 38
/// points instead of 22. An icon taller than the title makes the row taller rather than spill
/// into the next one. The Inspector's References tab lists the same rows a size down
/// (`FindResultCellStyle.Metrics.inspector`).
final class FindResultCellView: TableCellView {
    /// Above and below the icon and the title.
    private static let verticalPadding: CGFloat = 3

    private let metrics: FindResultCellStyle.Metrics

    private let iconImageView = ImageView()

    private let titleLabel = Label(wrappingLabelWithString: "")

    /// A row whose title takes one line: the icon, as tall as a line of the title, and the padding
    /// around it. A list whose rows never wrap fixes its rows at this height.
    static func singleLineRowHeight(for metrics: FindResultCellStyle.Metrics) -> CGFloat {
        metrics.iconSize + verticalPadding * 2
    }

    /// The Find navigator's row: what `makeView(ofClass:)` makes without a builder, through
    /// `NSView`'s `init()`.
    override init(frame frameRect: NSRect) {
        self.metrics = .navigator
        super.init(frame: frameRect)
    }

    init(metrics: FindResultCellStyle.Metrics) {
        self.metrics = metrics
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setup() {
        super.setup()

        hierarchy {
            iconImageView
            titleLabel
        }

        iconImageView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(6)
            make.top.equalToSuperview().offset(Self.verticalPadding)
            make.bottom.lessThanOrEqualToSuperview().inset(Self.verticalPadding)
            make.size.equalTo(metrics.iconSize)
        }

        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconImageView.snp.trailing).offset(6)
            make.trailing.equalToSuperview().inset(6)
            make.top.equalToSuperview().offset(Self.verticalPadding)
            make.bottom.equalToSuperview().inset(Self.verticalPadding)
        }

        iconImageView.do {
            $0.imageScaling = .scaleProportionallyDown
            $0.contentTintColor = FindResultCellStyle.iconTintColor
        }

        titleLabel.do {
            // A wrapping label is selectable; a row's title is not text to select. Selectable,
            // a click turned it into the field editor, which drew the title anew on one line.
            $0.isSelectable = false
            $0.alignment = .left
            $0.maximumNumberOfLines = 1
            $0.lineBreakMode = .byTruncatingTail
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
    }

    /// `configure(with:)`, not `bind(to:)`: a result row's appearance is fixed the moment the
    /// node is built, so there is nothing to observe.
    func configure(with appearance: FindResultCellAppearance) {
        iconImageView.image = appearance.icon
        iconImageView.alphaValue = appearance.iconAlpha
        iconImageView.contentTintColor = appearance.isSecondary ? FindResultCellStyle.unresolvedIconTintColor : FindResultCellStyle.iconTintColor
        titleLabel.attributedStringValue = appearance.title
        titleLabel.maximumNumberOfLines = appearance.allowsWrapping ? 2 : 1
        titleLabel.lineBreakMode = appearance.allowsWrapping ? .byWordWrapping : .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = appearance.allowsWrapping
    }
}
