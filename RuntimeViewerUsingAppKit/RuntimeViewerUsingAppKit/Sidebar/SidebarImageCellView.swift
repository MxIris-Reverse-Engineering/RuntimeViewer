import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerApplication

final class SidebarImageCellView: TableCellView {
    private let primaryIconImageView = ImageView()

    private let secondaryIconImageView = ImageView()

    private let nameLabel = Label()

    private lazy var contentStackView = HStackView(distribution: .fill, spacing: 6) {
        HStackView(distribution: .fill, spacing: 6) {
            primaryIconImageView
                .contentHugging(h: .required)
                .contentCompressionResistance(h: .required)
            secondaryIconImageView
                .contentHugging(h: .required)
                .contentCompressionResistance(h: .required)
        }
        nameLabel
            .contentHugging(h: .defaultLow)
            .contentCompressionResistance(h: .defaultLow)
    }

    override func setup() {
        super.setup()

        addSubview(contentStackView)

        contentStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        primaryIconImageView.do {
            $0.contentTintColor = .controlAccentColor
        }

        secondaryIconImageView.do {
            $0.contentTintColor = .controlAccentColor
            $0.isHidden = true
        }

        nameLabel.do {
            $0.alignment = .left
            $0.maximumNumberOfLines = 1
        }
    }

    func bind(to viewModel: SidebarImageCellViewModel) {
        rx.disposeBag = DisposeBag()
        viewModel.$primaryIcon.asDriver().drive(primaryIconImageView.rx.image).disposed(by: rx.disposeBag)
        viewModel.$secondaryIcon.asDriver().drive(secondaryIconImageView.rx.image).disposed(by: rx.disposeBag)
        viewModel.$secondaryIcon.asDriver().map { $0 == nil }.drive(secondaryIconImageView.rx.isHidden).disposed(by: rx.disposeBag)
        viewModel.$name.asDriver().drive(nameLabel.rx.attributedStringValue).disposed(by: rx.disposeBag)
    }
}
