import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

/// An image chosen in the pane's jump bar, before any of its objects (proposal `editor-jump-bar`):
/// the progress while the image is indexed, then a page naming the image and how many objects of
/// each kind it has, which the jump bar's last component lists; or why the image could not be
/// loaded, with Try Again.
///
/// Nothing shows for the first moments of the work, so an image indexed already appears without a
/// flash of progress (`ContentImageViewModel.State.starting`).
final class ContentImageViewController: BaseViewController<ContentImageViewModel> {
    private let progressView = ImageIndexingProgressView()

    private let iconView = ImageView()

    private let titleLabel = Label()

    private let pathLabel = Label()

    private let objectCountsLabel = Label()

    private let hintLabel = Label("Choose an object in the jump bar")

    private let failureLabel = Label()

    private let retryButton = PushButton()

    private lazy var summaryStackView = VStackView(alignment: .center, spacing: 6) {
        iconView
        titleLabel
        pathLabel
        objectCountsLabel
        hintLabel
    }

    private lazy var failureStackView = VStackView(alignment: .center, spacing: 12) {
        failureLabel
        retryButton
    }

    override var containerViewUsingSafeArea: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.hierarchy {
            progressView
            summaryStackView
            failureStackView
        }

        progressView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        summaryStackView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().inset(20)
            make.trailing.lessThanOrEqualToSuperview().inset(20)
        }

        failureStackView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.lessThanOrEqualTo(360)
            make.leading.greaterThanOrEqualToSuperview().inset(20)
            make.trailing.lessThanOrEqualToSuperview().inset(20)
        }

        summaryStackView.setCustomSpacing(10, after: iconView)
        summaryStackView.setCustomSpacing(12, after: pathLabel)
        summaryStackView.setCustomSpacing(16, after: objectCountsLabel)

        iconView.do {
            $0.contentTintColor = .tertiaryLabelColor
        }

        titleLabel.do {
            $0.font = .systemFont(ofSize: 20, weight: .regular)
            $0.textColor = .labelColor
            $0.lineBreakMode = .byTruncatingMiddle
        }

        pathLabel.do {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
            $0.lineBreakMode = .byTruncatingMiddle
            $0.isSelectable = true
        }

        objectCountsLabel.do {
            $0.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            $0.textColor = .secondaryLabelColor
            $0.alignment = .center
            $0.maximumNumberOfLines = 0
        }

        hintLabel.do {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .tertiaryLabelColor
        }

        failureLabel.do {
            $0.alignment = .center
            $0.maximumNumberOfLines = 0
            $0.isSelectable = true
        }

        retryButton.title = "Try Again"

        apply(.starting)
    }

    override func setupBindings(for viewModel: ContentImageViewModel) {
        super.setupBindings(for: viewModel)

        let imageIcon = RuntimeImageKind(ofImageAt: viewModel.imagePath).icon
        iconView.image = imageIcon.withSymbolConfiguration(.init(pointSize: 40, weight: .light))
        titleLabel.stringValue = viewModel.imageName
        pathLabel.stringValue = viewModel.imagePath

        let output = viewModel.transform(.init(retryClicked: retryButton.rx.click.asSignal()))

        output.state.driveOnNext { [weak self] state in
            guard let self else { return }
            apply(state)
        }
        .disposed(by: rx.disposeBag)

        output.indexingProgress.driveOnNext { [weak self] progress in
            guard let self else { return }
            progressView.show(fraction: progress.fraction, description: progress.description, itemCount: progress.itemCount)
        }
        .disposed(by: rx.disposeBag)
    }

    private func apply(_ state: ContentImageViewModel.State) {
        progressView.isHidden = state != .indexing
        switch state {
        case .indexed(let summary):
            objectCountsLabel.stringValue = Self.objectCountsText(of: summary)
            summaryStackView.isHidden = false
            failureStackView.isHidden = true
        case .failed(let message):
            failureLabel.stringValue = message
            summaryStackView.isHidden = true
            failureStackView.isHidden = false
        case .starting, .indexing:
            summaryStackView.isHidden = true
            failureStackView.isHidden = true
        }
    }

    /// One line per kind, as the sidebar's sections name the kinds: "1,820 · Objective-C Class".
    private static func objectCountsText(of summary: ContentImageViewModel.Summary) -> String {
        guard !summary.objectCounts.isEmpty else {
            return "No classes or protocols"
        }
        return summary.objectCounts
            .map { "\($0.count.formatted()) · \($0.kindTitle)" }
            .joined(separator: "\n")
    }
}

extension ContentImageViewController: EditorPaneContent {
    /// Nothing to type into: the pane keeps the focus on itself.
    var focusableView: NSView? { nil }
}
