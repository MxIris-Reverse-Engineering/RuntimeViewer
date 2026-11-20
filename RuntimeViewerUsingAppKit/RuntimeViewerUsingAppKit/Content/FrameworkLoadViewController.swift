import AppKit
import UniformTypeIdentifiers
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

/// The Load Frameworks page (proposal `isolated-framework-loading`): the framework loading; the one
/// dyld refused, with the diagnosis — what went wrong, the remedy on offer, the dependency chain,
/// where dyld looked and why there, dyld's own list and message; or the instance having gone away,
/// with Load Again.
///
/// Shown in an empty editor pane of a framework instance's window, where `Route` is the pane's, and
/// as a sheet over any window, where it has a Close button.
final class FrameworkLoadViewController<Route: Routable>: BaseViewController<FrameworkLoadViewModel<Route>> {
    // MARK: - Relays

    private let hostApplicationChosenRelay = PublishRelay<URL>()

    private let searchPathChosenRelay = PublishRelay<URL>()

    // MARK: - Loading

    private let progressIndicator = NSProgressIndicator().then {
        $0.style = .spinning
        $0.controlSize = .small
        $0.isDisplayedWhenStopped = false
    }

    private let loadingTitleLabel = Label()

    private let loadingDetailLabel = FrameworkLoadWrappingLabel()

    private lazy var loadingStackView = VStackView(alignment: .center, spacing: 8) {
        progressIndicator
        loadingTitleLabel
        loadingDetailLabel
    }

    // MARK: - Instance Stopped

    private let stoppedTitleLabel = Label()

    private let stoppedDetailLabel = FrameworkLoadWrappingLabel()

    private let loadAgainButton = PushButton()

    private lazy var stoppedStackView = VStackView(alignment: .center, spacing: 12) {
        stoppedTitleLabel
        stoppedDetailLabel
        loadAgainButton
    }

    // MARK: - Failure

    private let pageScrollView = ScrollView()

    private let titleLabel = FrameworkLoadWrappingLabel()

    private let summaryLabel = FrameworkLoadWrappingLabel()

    private let tagsLabel = FrameworkLoadWrappingLabel()

    private let bannerView = LayerBackedView()

    private let remedyExplanationLabel = FrameworkLoadWrappingLabel()

    private let remedyButton = PushButton()

    private let chooseHostApplicationButton = PushButton()

    private let addSearchPathButton = PushButton()

    private let retryButton = PushButton()

    private lazy var bannerButtonsStackView = HStackView(spacing: 8) {
        remedyButton
        chooseHostApplicationButton
        addSearchPathButton
        retryButton
    }

    private lazy var bannerStackView = VStackView(alignment: .leading, spacing: 10) {
        remedyExplanationLabel
        bannerButtonsStackView
    }

    private let chainTitleLabel = Label("Dependency chain")

    private let chainLabel = FrameworkLoadWrappingLabel()

    private let rpathTitleLabel = Label("Where it looked")

    private let rpathLabel = FrameworkLoadWrappingLabel()

    private let explanationLabel = FrameworkLoadWrappingLabel()

    private let triedTitleLabel = Label("Paths dyld tried")

    private let triedLabel = FrameworkLoadWrappingLabel()

    private let messageTitleLabel = Label("dyld message")

    private let messageLabel = FrameworkLoadWrappingLabel()

    private let copyDiagnosisButton = PushButton()

    private let showInFinderButton = PushButton()

    private let closeButton = PushButton()

    private lazy var footerStackView = HStackView(spacing: 8) {
        copyDiagnosisButton
        showInFinderButton
        closeButton
    }

    private lazy var failureStackView = VStackView(alignment: .leading, spacing: 12) {
        titleLabel
        summaryLabel
        tagsLabel
        bannerView
        chainTitleLabel
        chainLabel
        rpathTitleLabel
        rpathLabel
        explanationLabel
        triedTitleLabel
        triedLabel
        messageTitleLabel
        messageLabel
        footerStackView
    }

    // MARK: - Lifecycle

    override var containerViewUsingSafeArea: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()

        let documentView = FrameworkLoadDocumentView()
        documentView.hierarchy {
            failureStackView
        }
        pageScrollView.documentView = documentView
        bannerView.hierarchy {
            bannerStackView
        }
        containerView.hierarchy {
            pageScrollView
            loadingStackView
            stoppedStackView
        }

        pageScrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        documentView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.width.equalTo(pageScrollView.contentView)
        }
        failureStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(top: 22, left: 28, bottom: 28, right: 28))
        }
        bannerStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(12)
        }
        for wrappingView in [titleLabel, summaryLabel, tagsLabel, bannerView, chainLabel, rpathLabel, explanationLabel, triedLabel, messageLabel] as [NSView] {
            wrappingView.snp.makeConstraints { make in
                make.width.equalTo(failureStackView)
            }
        }
        remedyExplanationLabel.snp.makeConstraints { make in
            make.width.equalTo(bannerStackView)
        }
        loadingStackView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().inset(20)
            make.trailing.lessThanOrEqualToSuperview().inset(20)
        }
        stoppedStackView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.lessThanOrEqualTo(420)
            make.leading.greaterThanOrEqualToSuperview().inset(20)
            make.trailing.lessThanOrEqualToSuperview().inset(20)
        }

        failureStackView.setCustomSpacing(4, after: titleLabel)
        failureStackView.setCustomSpacing(18, after: tagsLabel)
        failureStackView.setCustomSpacing(18, after: bannerView)
        for sectionTitleLabel in [chainTitleLabel, rpathTitleLabel, triedTitleLabel, messageTitleLabel] {
            failureStackView.setCustomSpacing(4, after: sectionTitleLabel)
            sectionTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        }

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        summaryLabel.font = .systemFont(ofSize: 14)
        tagsLabel.do {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
        }
        bannerView.do {
            $0.cornerRadius = 10
            $0.borderWidth = 1
            $0.borderPositions = .all
            $0.backgroundColor = .controlAccentColor.withAlphaComponent(0.08)
            $0.borderColor = .controlAccentColor.withAlphaComponent(0.35)
        }
        for monospacedLabel in [chainLabel, rpathLabel, triedLabel, messageLabel] {
            monospacedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        explanationLabel.do {
            $0.font = .systemFont(ofSize: 12)
            $0.textColor = .secondaryLabelColor
        }

        loadingTitleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        loadingDetailLabel.textColor = .secondaryLabelColor
        stoppedTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        stoppedDetailLabel.do {
            $0.alignment = .center
            $0.textColor = .secondaryLabelColor
        }

        remedyButton.keyEquivalent = "\r"
        chooseHostApplicationButton.title = "Choose Host App…"
        addSearchPathButton.title = "Add Search Path…"
        retryButton.title = "Retry"
        copyDiagnosisButton.title = "Copy Diagnosis"
        showInFinderButton.title = "Show in Finder"
        closeButton.do {
            $0.title = "Close"
            $0.keyEquivalent = "\u{1b}"
        }
        loadAgainButton.do {
            $0.title = "Load Again"
            $0.keyEquivalent = "\r"
        }

        apply(.none)
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: FrameworkLoadViewModel<Route>) {
        super.setupBindings(for: viewModel)

        let output = viewModel.transform(.init(
            retryClicked: retryButton.rx.click.asSignal(),
            remedyClicked: remedyButton.rx.click.asSignal(),
            chooseHostApplicationClicked: chooseHostApplicationButton.rx.click.asSignal(),
            addSearchPathClicked: addSearchPathButton.rx.click.asSignal(),
            hostApplicationChosen: hostApplicationChosenRelay.asSignal(),
            searchPathChosen: searchPathChosenRelay.asSignal(),
            loadAgainClicked: loadAgainButton.rx.click.asSignal(),
            copyDiagnosisClicked: copyDiagnosisButton.rx.click.asSignal(),
            showInFinderClicked: showInFinderButton.rx.click.asSignal(),
            closeClicked: closeButton.rx.click.asSignal()
        ))

        output.page.driveOnNext { [weak self] page in
            guard let self else { return }
            apply(page)
        }
        .disposed(by: rx.disposeBag)

        output.requestHostApplication.emitOnNext { [weak self] in
            guard let self else { return }
            presentPanel(choosingDirectories: false, message: "Choose the app the framework belongs to.", into: hostApplicationChosenRelay)
        }
        .disposed(by: rx.disposeBag)

        output.requestSearchPath.emitOnNext { [weak self] in
            guard let self else { return }
            presentPanel(choosingDirectories: true, message: "Choose a folder to search for the framework's dependencies.", into: searchPathChosenRelay)
        }
        .disposed(by: rx.disposeBag)
    }

    // MARK: - Page Management

    private func apply(_ page: FrameworkLoadPage) {
        loadingStackView.isHidden = true
        stoppedStackView.isHidden = true
        pageScrollView.isHidden = true
        progressIndicator.stopAnimation(nil)
        switch page {
        case .none:
            break
        case .loading(let title, let detail):
            loadingStackView.isHidden = false
            progressIndicator.startAnimation(nil)
            loadingTitleLabel.stringValue = title
            loadingDetailLabel.stringValue = detail ?? ""
            loadingDetailLabel.isHidden = detail == nil
        case .failure(let presentation, let actions):
            pageScrollView.isHidden = false
            apply(presentation, actions: actions)
        case .instanceStopped(let title, let detail):
            stoppedStackView.isHidden = false
            stoppedTitleLabel.stringValue = title
            stoppedDetailLabel.stringValue = detail
        }
    }

    private func apply(_ presentation: ImageLoadDiagnosisPresentation, actions: FrameworkLoadPageActions) {
        titleLabel.stringValue = presentation.title
        summaryLabel.stringValue = presentation.summary
        tagsLabel.stringValue = presentation.tags.joined(separator: "  ·  ")

        let offersSomething = presentation.remedyTitle != nil || actions.canChooseHostApplication || actions.canAddSearchPath
        bannerView.isHidden = !offersSomething
        remedyExplanationLabel.stringValue = presentation.remedyExplanation
            ?? "Choose the app this framework belongs to, or a folder to search, and RuntimeViewer looks for its dependencies there."
        remedyButton.title = presentation.remedyTitle ?? ""
        remedyButton.isHidden = !actions.canApplyRemedy
        chooseHostApplicationButton.isHidden = !actions.canChooseHostApplication
        addSearchPathButton.isHidden = !actions.canAddSearchPath
        retryButton.isHidden = !actions.canRetry

        chainLabel.stringValue = presentation.chain.map { $0.isMissing ? "\($0.name) ✗" : $0.name }.joined(separator: "  →  ")
        chainTitleLabel.isHidden = presentation.chain.isEmpty
        chainLabel.isHidden = presentation.chain.isEmpty

        rpathLabel.stringValue = presentation.rpathRows.map { row in
            "\(row.ownerName) (\(row.ownerRole))\n    \(row.rpath)  →  \(row.candidatePath)  —  \(row.outcome)"
        }.joined(separator: "\n")
        rpathTitleLabel.isHidden = presentation.rpathRows.isEmpty
        rpathLabel.isHidden = presentation.rpathRows.isEmpty

        explanationLabel.stringValue = presentation.explanations.map { "Why: \($0)" }.joined(separator: "\n")
        explanationLabel.isHidden = presentation.explanations.isEmpty

        triedLabel.stringValue = presentation.triedRows.map { "\($0.path)  —  \($0.reason)" }.joined(separator: "\n")
        triedTitleLabel.isHidden = presentation.triedRows.isEmpty
        triedLabel.isHidden = presentation.triedRows.isEmpty

        messageLabel.stringValue = presentation.dyldMessage
        closeButton.isHidden = !actions.canClose
    }

    // MARK: - Actions

    private func presentPanel(choosingDirectories: Bool, message: String, into relay: PublishRelay<URL>) {
        guard let window = view.window else { return }
        let openPanel = NSOpenPanel()
        openPanel.message = message
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = choosingDirectories
        openPanel.canChooseFiles = !choosingDirectories
        if !choosingDirectories {
            openPanel.allowedContentTypes = [.application]
        }
        openPanel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = openPanel.url else { return }
            relay.accept(url)
        }
    }
}

/// The scrolling page's document view, laid out from the top. At file scope rather than nested:
/// a type nested in the generic view controller would be generic too.
private final class FrameworkLoadDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A selectable label that wraps at the width layout gives it and asks for none of its own.
///
/// With `preferredMaxLayoutWidth` at 0, a wrapping text field's intrinsic width is its whole text on
/// one line, held at the default compression resistance (750) — above the priority a window keeps
/// its size at (500). The dyld message and the rpath rows run to well over a thousand points on one
/// line, so the sheet grew wider than the window it sits on and, centred on it, put the page's text
/// off the screen. This label resists compression below that priority, so the width comes from the
/// page, and wraps at the width it is laid out at, so its intrinsic height covers every line.
private final class FrameworkLoadWrappingLabel: Label {
    override func setup() {
        super.setup()
        maximumNumberOfLines = 0
        lineBreakMode = .byWordWrapping
        isSelectable = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard preferredMaxLayoutWidth != newSize.width else { return }
        preferredMaxLayoutWidth = newSize.width
    }
}
