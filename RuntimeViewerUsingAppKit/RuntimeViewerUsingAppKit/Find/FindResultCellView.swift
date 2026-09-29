import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import SnapKit

/// A row of the Find navigator's outline: Xcode's `IDEFindNavigatorTableCellView` — a 16-point
/// icon at the leading edge, the title 19 points in, both 3 points down; a hit's line wraps
/// onto a second line, which makes the row 38 points instead of 22.
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
            make.size.equalTo(16)
        }

        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(19)
            make.trailing.equalToSuperview().inset(4)
            make.top.equalToSuperview().offset(3)
            make.bottom.equalToSuperview().inset(3)
        }

        iconImageView.do {
            $0.imageScaling = .scaleProportionallyDown
            $0.contentTintColor = .secondaryLabelColor
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
        iconImageView.contentTintColor = appearance.isSecondary ? .tertiaryLabelColor : .secondaryLabelColor
        titleLabel.attributedStringValue = appearance.title
        titleLabel.maximumNumberOfLines = appearance.allowsWrapping ? 2 : 1
        titleLabel.lineBreakMode = appearance.allowsWrapping ? .byWordWrapping : .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = appearance.allowsWrapping
    }
}
