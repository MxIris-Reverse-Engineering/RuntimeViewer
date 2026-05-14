import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class RuntimeObjectCellView<ViewModel: RuntimeObjectCellDisplayable>: TableCellView {
    private let primaryIconImageView = ImageView()

    private let secondaryIconImageView = ImageView()

    private let tertiaryIconImageView = ImageView()

    private let titleLabel = Label()

    private let subtitleLabel = Label()

    var contentInsets: NSEdgeInsets = .init()

    var minimumHeight: CGFloat?

    private lazy var textStackView = VStackView(alignment: .leading, spacing: 2) {
        titleLabel
        subtitleLabel
    }

    private lazy var contentStackView = HStackView(distribution: .fill, spacing: 6) {
        primaryIconImageView
            .contentHugging(h: .required)
            .contentCompressionResistance(h: .required)
        secondaryIconImageView
            .contentHugging(h: .required)
            .contentCompressionResistance(h: .required)
        tertiaryIconImageView
            .contentHugging(h: .required)
            .contentCompressionResistance(h: .required)
        textStackView
            .contentHugging(h: .defaultLow)
            .contentCompressionResistance(h: .defaultLow)
    }

    override func setup() {
        super.setup()

        addSubview(contentStackView)

        contentStackView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(contentInsets.top)
            make.bottom.equalToSuperview().offset(-contentInsets.bottom)
            make.leading.equalToSuperview().offset(contentInsets.left)
            make.trailing.equalToSuperview().offset(-contentInsets.right)
            if let minimumHeight {
                make.height.greaterThanOrEqualTo(minimumHeight)
            }
        }

        primaryIconImageView.do {
            $0.contentTintColor = .controlAccentColor
        }

        [secondaryIconImageView, tertiaryIconImageView].forEach {
            $0.contentTintColor = .controlAccentColor
            $0.isHidden = true
        }

        titleLabel.do {
            $0.alignment = .left
            $0.maximumNumberOfLines = 1
        }

        subtitleLabel.do {
            $0.alignment = .left
            $0.maximumNumberOfLines = 1
            $0.isHidden = true
        }
    }

    func bind(to viewModel: ViewModel) {
        rx.disposeBag = DisposeBag()

        viewModel.primaryIconDriver.drive(primaryIconImageView.rx.image).disposed(by: rx.disposeBag)
        
        viewModel.secondaryIconDriver.drive(secondaryIconImageView.rx.image).disposed(by: rx.disposeBag)
        viewModel.secondaryIconDriver.map { $0 == nil }.drive(secondaryIconImageView.rx.isHidden).disposed(by: rx.disposeBag)
        
        viewModel.tertiaryIconDriver.drive(tertiaryIconImageView.rx.image).disposed(by: rx.disposeBag)
        viewModel.tertiaryIconDriver.map { $0 == nil }.drive(tertiaryIconImageView.rx.isHidden).disposed(by: rx.disposeBag)
        
        viewModel.titleDriver.drive(titleLabel.rx.attributedStringValue).disposed(by: rx.disposeBag)
        
        viewModel.subtitleDriver.map { $0 ?? NSAttributedString() }.drive(subtitleLabel.rx.attributedStringValue).disposed(by: rx.disposeBag)
        viewModel.subtitleDriver.map { $0 == nil }.drive(subtitleLabel.rx.isHidden).disposed(by: rx.disposeBag)
    }
}
