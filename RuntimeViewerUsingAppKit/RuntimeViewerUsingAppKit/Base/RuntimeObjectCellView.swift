import AppKit
import AppKitPlus
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class RuntimeObjectCellView<ViewModel: RuntimeObjectCellDisplayable>: TableCellView {
    private let primaryIconImageView = ImageView()

    private let secondaryIconImageView = ImageView()

    private let tertiaryIconImageView = ImageView()

    private let titleLabel = Label()

    private let subtitleLabel = Label()

    /// The appearance's tags, after the title: one `TagButton` each, rebuilt
    /// only when the tags change.
    private let tagStackView = HStackView(spacing: 4) {}

    private var tagButtons: [TagButton] = []

    private var appliedTags: [RuntimeObjectCellTag] = []

    /// Clicks on the buttons of the tags currently applied; replaced with them.
    private var tagButtonDisposeBag = DisposeBag()

    /// The tag buttons are rebuilt with the row's data, so their clicks are
    /// gathered here rather than exposed one control at a time.
    private let tagClickedRelay = PublishRelay<RuntimeObjectCellTag.Identifier>()

    /// The identifier of each clickable tag a click lands on. The list's view
    /// controller pairs it with the row it bound this cell to.
    var tagClicked: Signal<RuntimeObjectCellTag.Identifier> {
        tagClickedRelay.asSignal()
    }

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
        // After a title that takes the slack, so tags line up at the row's
        // trailing edge; the title truncates before a tag does. A stack view
        // has no intrinsic size, so content hugging does nothing for it: it
        // hugs its views with its own hugging priority, which defaults to
        // `.defaultLow` — the text stack's too. With the two equal, Auto
        // Layout widened either one, and a row whose tag stack it widened
        // showed the tag right after the title.
        tagStackView
            .box
            .hugging(h: NSLayoutConstraint.Priority.defaultHigh.rawValue)
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
        }

        subtitleLabel.do {
            $0.alignment = .left
            $0.maximumNumberOfLines = 1
            $0.isHidden = true
        }

        tagStackView.isHidden = true

        let viewsWithTooltip: [NSView] = [primaryIconImageView, secondaryIconImageView, tertiaryIconImageView, titleLabel, subtitleLabel]
        for viewWithTooltip in viewsWithTooltip {
            viewWithTooltip.customTooltipStyle = .runtimeObjectCell
        }
    }

    func bind(to viewModel: ViewModel) {
        rx.disposeBag = DisposeBag()

        viewModel.appearanceDriver.driveOnNext { [weak self] appearance in
            guard let self else { return }
            apply(appearance)
        }
        .disposed(by: rx.disposeBag)
    }

    private func apply(_ appearance: RuntimeObjectCellAppearance) {
        primaryIconImageView.image = appearance.primaryIcon
        primaryIconImageView.toolTip = appearance.primaryTooltip

        secondaryIconImageView.image = appearance.secondaryIcon
        secondaryIconImageView.toolTip = appearance.secondaryTooltip
        secondaryIconImageView.isHidden = appearance.secondaryIcon == nil

        tertiaryIconImageView.image = appearance.tertiaryIcon
        tertiaryIconImageView.toolTip = appearance.tertiaryTooltip
        tertiaryIconImageView.isHidden = appearance.tertiaryIcon == nil

        titleLabel.attributedStringValue = appearance.title

        subtitleLabel.attributedStringValue = appearance.subtitle ?? NSAttributedString()
        subtitleLabel.isHidden = appearance.subtitle == nil

        apply(appearance.tags)
    }

    private func apply(_ tags: [RuntimeObjectCellTag]) {
        guard tags != appliedTags else { return }
        appliedTags = tags
        tagButtonDisposeBag = DisposeBag()
        while tagButtons.count < tags.count {
            let tagButton = TagButton()
            tagButton.customTooltipStyle = .runtimeObjectCell
            tagButtons.append(tagButton)
        }
        let shownTagButtons = Array(tagButtons.prefix(tags.count))
        for (tagButton, tag) in zip(shownTagButtons, tags) {
            tagButton.title = tag.title
            tagButton.toolTip = tag.toolTip
            tagButton.isClickable = tag.isClickable
            tagButton.rx.click
                .asSignal()
                .map { tag.identifier }
                .emit(to: tagClickedRelay)
                .disposed(by: tagButtonDisposeBag)
        }
        tagStackView.setViews(shownTagButtons, in: .leading)
        tagStackView.isHidden = tags.isEmpty
    }

    /// The button showing the tag `identifier` names, for a popover to anchor at.
    func tagView(for identifier: RuntimeObjectCellTag.Identifier) -> NSView? {
        zip(tagButtons, appliedTags).first { _, tag in tag.identifier == identifier }?.0
    }
}

extension ToolTipStyle {
    /// Every tooltip in a runtime-object cell: the three icons, both labels
    /// and the tags. Built on `.default`, not `.system`: a corner radius makes
    /// UIFoundation swap the system's blurred background for a plain layer,
    /// and a style without a colour of its own would then have that layer
    /// filled with AppKit's private `toolTipColor`, which is made to go with
    /// the blur. `.default` brings a solid background, a hairline border and a
    /// light shadow.
    fileprivate static let runtimeObjectCell = ToolTipStyle.default.with {
        $0.cornerRadius = 8
    }
}
