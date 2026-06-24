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

    let contentInsets: NSEdgeInsets

    let minimumHeight: CGFloat?

    convenience init() {
        self.init(contentInsets: .init())
    }
    
    init(contentInsets: NSEdgeInsets, minimumHeight: CGFloat? = nil) {
        self.contentInsets = contentInsets
        self.minimumHeight = minimumHeight
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private lazy var textStackView = VStackView(distribution: .fill, alignment: .leading, spacing: 2) {
        titleLabel
            .box
            .contentCompressionResistance(h: .defaultLow)
        subtitleLabel
            .box
            .contentCompressionResistance(h: .defaultLow)
    }

    private lazy var contentStackView = HStackView(distribution: .fill, spacing: 6) {
        primaryIconImageView
            .box
            .contentHugging(h: .required)
            .box
            .contentCompressionResistance(h: .required)
        secondaryIconImageView
            .box
            .contentHugging(h: .required)
            .box
            .contentCompressionResistance(h: .required)
        tertiaryIconImageView
            .box
            .contentHugging(h: .required)
            .box
            .contentCompressionResistance(h: .required)
        textStackView
            .box
            .contentHugging(h: .defaultLow)
            .box
            .contentCompressionResistance(h: .defaultLow)
    }

    override func setup() {
        super.setup()

        addSubview(contentStackView)

        contentStackView.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(contentInsets.top)
            make.bottom.equalToSuperview().inset(contentInsets.bottom)
            make.leading.equalToSuperview().inset(contentInsets.left)
            make.trailing.equalToSuperview().inset(contentInsets.right)

            if let minimumHeight {
                make.height.greaterThanOrEqualTo(minimumHeight)
            }
        }

        primaryIconImageView.do {
            $0.contentTintColor = .controlAccentColor
        }

        for item in [secondaryIconImageView, tertiaryIconImageView] {
            item.contentTintColor = .controlAccentColor
            item.isHidden = true
        }

        titleLabel.do {
            $0.alignment = .left
            $0.maximumNumberOfLines = 1
            $0.syncStringValueToolTip = true
        }

        subtitleLabel.do {
            $0.alignment = .left
            $0.maximumNumberOfLines = 1
            $0.isHidden = true
            $0.syncStringValueToolTip = true
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
