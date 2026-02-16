import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingViewController: AppKitViewController<ExportingViewModel> {
    // MARK: - Relays

    private let cancelRelay = PublishRelay<Void>()
    private let exportRelay = PublishRelay<Void>()
    private let doneRelay = PublishRelay<Void>()
    private let showInFinderRelay = PublishRelay<Void>()
    private let formatSelectedRelay = PublishRelay<Int>()

    // MARK: - Configuration Page

    private let configImageNameLabel = Label()

    private let configSingleFileRadio = NSButton()

    private let configDirectoryRadio = NSButton()

    private lazy var configPageView: NSView = {
        let container = NSView()

        let iconImageView = ImageView().then {
            $0.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            $0.symbolConfiguration = .init(pointSize: 32, weight: .light)
            $0.contentTintColor = .controlAccentColor
        }

        let titleLabel = Label("Export Interfaces").then {
            $0.font = .systemFont(ofSize: 18, weight: .semibold)
        }

        let headerStack = HStackView(spacing: 10) {
            iconImageView
            titleLabel
        }.then {
            $0.alignment = .centerY
        }

        let imageNameTitleLabel = Label("Image:").then {
            $0.font = .systemFont(ofSize: 13, weight: .medium)
        }

        configImageNameLabel.do {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .secondaryLabelColor
        }

        let imageNameStack = HStackView(spacing: 4) {
            imageNameTitleLabel
            configImageNameLabel
        }

        configSingleFileRadio.do {
            $0.setButtonType(.radio)
            $0.title = "Single File"
            $0.font = .systemFont(ofSize: 13)
            $0.state = .on
            $0.target = self
            $0.action = #selector(formatRadioChanged(_:))
            $0.tag = 0
        }

        let singleFileDescLabel = Label("Combine all interfaces into one .h and one .swiftinterface file").then {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .tertiaryLabelColor
        }

        let singleFileStack = VStackView(alignment: .leading, spacing: 2) {
            configSingleFileRadio
            singleFileDescLabel
        }

        configDirectoryRadio.do {
            $0.setButtonType(.radio)
            $0.title = "Directory Structure"
            $0.font = .systemFont(ofSize: 13)
            $0.state = .off
            $0.target = self
            $0.action = #selector(formatRadioChanged(_:))
            $0.tag = 1
        }

        let directoryDescLabel = Label("Individual files organized by ObjC/Swift subdirectories").then {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .tertiaryLabelColor
        }

        let directoryStack = VStackView(alignment: .leading, spacing: 2) {
            configDirectoryRadio
            directoryDescLabel
        }

        let formatTitleLabel = Label("Export Format:").then {
            $0.font = .systemFont(ofSize: 13, weight: .medium)
        }

        let formatStack = VStackView(alignment: .leading, spacing: 8) {
            formatTitleLabel
            singleFileStack
            directoryStack
        }

        let contentStack = VStackView(alignment: .leading, spacing: 16) {
            headerStack
            imageNameStack
            formatStack
        }

        let cancelButton = PushButton().then {
            $0.title = "Cancel"
            $0.keyEquivalent = "\u{1b}"
            $0.target = self
            $0.action = #selector(cancelClicked)
        }

        let exportButton = PushButton().then {
            $0.title = "Export\u{2026}"
            $0.keyEquivalent = "\r"
            $0.target = self
            $0.action = #selector(exportClicked)
        }

        let buttonStack = HStackView(spacing: 8) {
            cancelButton
            exportButton
        }

        container.hierarchy {
            contentStack
            buttonStack
        }

        contentStack.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(20)
        }

        buttonStack.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(20)
        }

        return container
    }()

    // MARK: - Progress Page

    private let progressPhaseLabel = Label("Preparing...").then {
        $0.font = .systemFont(ofSize: 15, weight: .medium)
        $0.alignment = .center
    }

    private let progressIndicator = NSProgressIndicator().then {
        $0.style = .bar
        $0.isIndeterminate = false
        $0.minValue = 0
        $0.maxValue = 1
    }

    private let progressObjectLabel = Label().then {
        $0.font = .systemFont(ofSize: 12)
        $0.textColor = .secondaryLabelColor
        $0.alignment = .center
    }

    private lazy var progressPageView: NSView = {
        let container = NSView()

        let contentStack = VStackView(alignment: .centerX, spacing: 12) {
            progressPhaseLabel
            progressIndicator
            progressObjectLabel
        }

        let cancelButton = PushButton().then {
            $0.title = "Cancel"
            $0.keyEquivalent = "\u{1b}"
            $0.target = self
            $0.action = #selector(cancelClicked)
        }

        container.hierarchy {
            contentStack
            cancelButton
        }

        progressIndicator.snp.makeConstraints { make in
            make.width.equalTo(350)
        }

        contentStack.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview().offset(-20)
            make.leading.greaterThanOrEqualToSuperview().offset(20)
            make.trailing.lessThanOrEqualToSuperview().offset(-20)
        }

        cancelButton.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(20)
        }

        return container
    }()

    // MARK: - Completion Page

    private let completionSummaryLabel = Label().then {
        $0.font = .systemFont(ofSize: 13)
        $0.textColor = .secondaryLabelColor
        $0.alignment = .center
        $0.maximumNumberOfLines = 0
        $0.preferredMaxLayoutWidth = 350
    }

    private lazy var completionPageView: NSView = {
        let container = NSView()

        let checkmarkImageView = ImageView().then {
            $0.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            $0.symbolConfiguration = .init(pointSize: 48, weight: .light)
            $0.contentTintColor = .systemGreen
        }

        let titleLabel = Label("Export Complete").then {
            $0.font = .systemFont(ofSize: 18, weight: .semibold)
            $0.alignment = .center
        }

        let contentStack = VStackView(alignment: .centerX, spacing: 8) {
            checkmarkImageView
            titleLabel
            completionSummaryLabel
        }

        let showInFinderButton = PushButton().then {
            $0.title = "Show in Finder"
            $0.target = self
            $0.action = #selector(showInFinderClicked)
        }

        let doneButton = PushButton().then {
            $0.title = "Done"
            $0.keyEquivalent = "\r"
            $0.target = self
            $0.action = #selector(doneClicked)
        }

        let buttonStack = HStackView(spacing: 8) {
            showInFinderButton
            doneButton
        }

        container.hierarchy {
            contentStack
            buttonStack
        }

        contentStack.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview().offset(-20)
        }

        buttonStack.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(20)
        }

        return container
    }()

    // MARK: - Container

    private let containerView = NSView()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.addSubview(containerView)

        containerView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        preferredContentSize = NSSize(width: 500, height: 350)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        showPage(configPageView)
    }

    // MARK: - Actions

    @objc private func cancelClicked() {
        cancelRelay.accept(())
    }

    @objc private func exportClicked() {
        exportRelay.accept(())
    }

    @objc private func doneClicked() {
        doneRelay.accept(())
    }

    @objc private func showInFinderClicked() {
        showInFinderRelay.accept(())
    }

    @objc private func formatRadioChanged(_ sender: NSButton) {
        configSingleFileRadio.state = sender.tag == 0 ? .on : .off
        configDirectoryRadio.state = sender.tag == 1 ? .on : .off
        formatSelectedRelay.accept(sender.tag)
    }

    // MARK: - Page Management

    private func showPage(_ page: NSView) {
        containerView.subviews.forEach { $0.removeFromSuperview() }
        containerView.addSubview(page)
        page.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: ExportingViewModel) {
        super.setupBindings(for: viewModel)

        let input = ExportingViewModel.Input(
            cancelClick: cancelRelay.asSignal(),
            exportClick: exportRelay.asSignal(),
            doneClick: doneRelay.asSignal(),
            showInFinderClick: showInFinderRelay.asSignal(),
            formatSelected: formatSelectedRelay.asSignal()
        )

        let output = viewModel.transform(input)

        output.currentPage.driveOnNext { [weak self] page in
            guard let self else { return }
            switch page {
            case .configuration:
                showPage(configPageView)
            case .progress:
                showPage(progressPageView)
            case .completion:
                showPage(completionPageView)
            }
        }
        .disposed(by: rx.disposeBag)

        output.imageName.drive(configImageNameLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.phaseText.drive(progressPhaseLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.progressValue.driveOnNext { [weak self] value in
            guard let self else { return }
            progressIndicator.doubleValue = value
        }
        .disposed(by: rx.disposeBag)

        output.currentObjectText.drive(progressObjectLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.result.compactMap { $0 }.driveOnNext { [weak self] result in
            guard let self else { return }
            var lines: [String] = []
            lines.append("\(result.succeeded) interfaces exported successfully")
            if result.failed > 0 {
                lines.append("\(result.failed) failed")
            }
            lines.append(String(format: "Duration: %.1fs", result.totalDuration))
            lines.append("ObjC: \(result.objcCount) | Swift: \(result.swiftCount)")
            completionSummaryLabel.stringValue = lines.joined(separator: "\n")
        }
        .disposed(by: rx.disposeBag)

        output.requestDirectorySelection.emit(onNext: { [weak self] in
            guard let self else { return }
            presentDirectoryPicker()
        })
        .disposed(by: rx.disposeBag)
    }

    private func presentDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a destination folder for exported interfaces"

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return }
            viewModel?.startExport(to: url)
        }
    }
}
