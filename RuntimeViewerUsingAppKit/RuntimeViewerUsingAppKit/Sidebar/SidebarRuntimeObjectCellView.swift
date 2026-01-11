import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerApplication

final class SidebarRuntimeObjectCellView: TableCellView {
    private let primaryIconImageView = ImageView()

    private let secondaryIconImageView = ImageView()

    private let nameLabel = Label()

    private let forOpenQuickly: Bool

    private lazy var contentStackView = HStackView(distribution: .fill, spacing: 6) {
        primaryIconImageView
            .contentHugging(h: .required)
            .contentCompressionResistance(h: .required)
        secondaryIconImageView
            .contentHugging(h: .required)
            .contentCompressionResistance(h: .required)
        nameLabel
            .contentHugging(h: .defaultLow)
            .contentCompressionResistance(h: .defaultLow)
    }

    init(forOpenQuickly: Bool) {
        self.forOpenQuickly = forOpenQuickly
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setup() {
        super.setup()

        addSubview(contentStackView)

        contentStackView.snp.makeConstraints { make in
            if forOpenQuickly {
                make.top.bottom.equalToSuperview()
                make.leading.trailing.equalToSuperview().inset(8)
                make.height.greaterThanOrEqualTo(40)
            } else {
                make.edges.equalToSuperview()
            }
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

    func bind(to viewModel: SidebarRuntimeObjectCellViewModel) {
        rx.disposeBag = DisposeBag()

        viewModel.$primaryIcon.asDriver().drive(primaryIconImageView.rx.image).disposed(by: rx.disposeBag)
        viewModel.$secondaryIcon.asDriver().drive(secondaryIconImageView.rx.image).disposed(by: rx.disposeBag)
        viewModel.$secondaryIcon.asDriver().map { $0 == nil }.drive(secondaryIconImageView.rx.isHidden).disposed(by: rx.disposeBag)
        viewModel.$name.asDriver().drive(nameLabel.rx.attributedStringValue).disposed(by: rx.disposeBag)
    }
}
