import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import SnapKit

/// A row of the Find navigator's outline: Xcode's `IDEFindNavigatorTableCellView` — the icon
/// (`FindResultCellStyle.iconSize`, 16 points in Xcode) at the leading edge, the title 3 points
/// after it, both 3 points down; a hit's line wraps onto a second line, which makes the row 38
/// points instead of 22. An icon taller than the title makes the row taller rather than spill
/// into the next one.
final class FindResultCellView: TableCellView {
    private let iconImageView = ImageView()

    private let titleLabel = Label(wrappingLabelWithString: "")

    override func setup() {
        super.setup()

        hierarchy {
            iconImageView
            titleLabel
        }

        iconImageView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.top.equalToSuperview().offset(3)
            make.bottom.lessThanOrEqualToSuperview().inset(3)
            make.size.equalTo(FindResultCellStyle.iconSize)
        }

        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconImageView.snp.trailing).offset(3)
            make.trailing.equalToSuperview().inset(4)
            make.top.equalToSuperview().offset(3)
            make.bottom.equalToSuperview().inset(3)
        }

        iconImageView.do {
            $0.imageScaling = .scaleProportionallyDown
            $0.contentTintColor = FindResultCellStyle.iconTintColor
        }

        titleLabel.do {
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
