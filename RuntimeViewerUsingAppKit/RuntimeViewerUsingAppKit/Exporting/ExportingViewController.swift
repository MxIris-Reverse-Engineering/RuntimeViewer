import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingViewController: AppKitViewController<ExportingViewModel> {
    // MARK: - Shared

    private let cancelRelay = PublishRelay<Void>()
    private let exportRelay = PublishRelay<Void>()
    private let doneRelay = PublishRelay<Void>()
    private let showInFinderRelay = PublishRelay<Void>()
    private let formatSelectedRelay = PublishRelay<Int>()

    // MARK: - Configuration Page

    private lazy var configPageView: NSView = {
        let container = NSView()

        let iconImageView = NSImageView()
        iconImageView.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        iconImageView.symbolConfiguration = .init(pointSize: 32, weight: .light)
        iconImageView.contentTintColor = .controlAccentColor

        let titleLabel = NSTextField(labelWithString: "Export Interfaces")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)

        let headerStack = NSStackView(views: [iconImageView, titleLabel])
        headerStack.orientation = .horizontal
        headerStack.spacing = 10
        headerStack.alignment = .centerY

        let imageNameTitleLabel = NSTextField(labelWithString: "Image:")
        imageNameTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        imageNameLabel.font = .systemFont(ofSize: 13)
        imageNameLabel.textColor = .secondaryLabelColor

        let imageNameStack = NSStackView(views: [imageNameTitleLabel, imageNameLabel])
        imageNameStack.orientation = .horizontal
        imageNameStack.spacing = 4

        let formatTitleLabel = NSTextField(labelWithString: "Export Format:")
        formatTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        singleFileRadio.setButtonType(.radio)
        singleFileRadio.title = "Single File"
        singleFileRadio.font = .systemFont(ofSize: 13)
        singleFileRadio.state = .on
        singleFileRadio.target = self
        singleFileRadio.action = #selector(formatRadioChanged(_:))
        singleFileRadio.tag = 0

        let singleFileDesc = NSTextField(labelWithString: "Combine all interfaces into one .h and one .swiftinterface file")
        singleFileDesc.font = .systemFont(ofSize: 11)
        singleFileDesc.textColor = .tertiaryLabelColor

        directoryRadio.setButtonType(.radio)
        directoryRadio.title = "Directory Structure"
        directoryRadio.font = .systemFont(ofSize: 13)
        directoryRadio.state = .off
        directoryRadio.target = self
        directoryRadio.action = #selector(formatRadioChanged(_:))
        directoryRadio.tag = 1

        let directoryDesc = NSTextField(labelWithString: "Individual files organized by ObjC/Swift subdirectories")
        directoryDesc.font = .systemFont(ofSize: 11)
        directoryDesc.textColor = .tertiaryLabelColor

        let singleFileStack = NSStackView(views: [singleFileRadio, singleFileDesc])
        singleFileStack.orientation = .vertical
        singleFileStack.alignment = .leading
        singleFileStack.spacing = 2

        let directoryStack = NSStackView(views: [directoryRadio, directoryDesc])
        directoryStack.orientation = .vertical
        directoryStack.alignment = .leading
        directoryStack.spacing = 2

        let formatStack = NSStackView(views: [formatTitleLabel, singleFileStack, directoryStack])
        formatStack.orientation = .vertical
        formatStack.alignment = .leading
        formatStack.spacing = 8

        let contentStack = NSStackView(views: [headerStack, imageNameStack, formatStack])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16

        let configCancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        configCancelButton.keyEquivalent = "\u{1b}" // Escape

        let exportButton = NSButton(title: "Export\u{2026}", target: self, action: #selector(exportClicked))
        exportButton.keyEquivalent = "\r"
        exportButton.bezelStyle = .rounded

        let buttonStack = NSStackView(views: [configCancelButton, exportButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        container.addSubview(contentStack)
        container.addSubview(buttonStack)

        contentStack.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(20)
        }

        buttonStack.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(20)
        }

        return container
    }()

    private let imageNameLabel = NSTextField(labelWithString: "")
    private let singleFileRadio = NSButton()
    private let directoryRadio = NSButton()

    // MARK: - Progress Page

    private lazy var progressPageView: NSView = {
        let container = NSView()

        phaseLabel.font = .systemFont(ofSize: 15, weight: .medium)
        phaseLabel.alignment = .center

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1

        objectLabel.font = .systemFont(ofSize: 12)
        objectLabel.textColor = .secondaryLabelColor
        objectLabel.alignment = .center

        let progressCancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        progressCancelButton.keyEquivalent = "\u{1b}"

        let contentStack = NSStackView(views: [phaseLabel, progressIndicator, objectLabel])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 12

        container.addSubview(contentStack)
        container.addSubview(progressCancelButton)

        progressIndicator.snp.makeConstraints { make in
            make.width.equalTo(350)
        }

        contentStack.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview().offset(-20)
            make.leading.greaterThanOrEqualToSuperview().offset(20)
            make.trailing.lessThanOrEqualToSuperview().offset(-20)
        }

        progressCancelButton.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(20)
        }

        return container
    }()

    private let phaseLabel = NSTextField(labelWithString: "Preparing...")
    private let progressIndicator = NSProgressIndicator()
    private let objectLabel = NSTextField(labelWithString: "")

    // MARK: - Completion Page

    private lazy var completionPageView: NSView = {
        let container = NSView()

        let checkmarkImageView = NSImageView()
        checkmarkImageView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        checkmarkImageView.symbolConfiguration = .init(pointSize: 48, weight: .light)
        checkmarkImageView.contentTintColor = .systemGreen

        let completeTitleLabel = NSTextField(labelWithString: "Export Complete")
        completeTitleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        completeTitleLabel.alignment = .center

        summaryLabel.font = .systemFont(ofSize: 13)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.alignment = .center
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.preferredMaxLayoutWidth = 350

        let contentStack = NSStackView(views: [checkmarkImageView, completeTitleLabel, summaryLabel])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 8

        let showInFinderButton = NSButton(title: "Show in Finder", target: self, action: #selector(showInFinderClicked))

        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        doneButton.keyEquivalent = "\r"

        let buttonStack = NSStackView(views: [showInFinderButton, doneButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        container.addSubview(contentStack)
        container.addSubview(buttonStack)

        contentStack.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview().offset(-20)
        }

        buttonStack.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(20)
        }

        return container
    }()

    private let summaryLabel = NSTextField(labelWithString: "")

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
        singleFileRadio.state = sender.tag == 0 ? .on : .off
        directoryRadio.state = sender.tag == 1 ? .on : .off
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

        output.currentPage
            .driveOnNext { [weak self] page in
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

        output.imageName
            .driveOnNext { [weak self] name in
                self?.imageNameLabel.stringValue = name
            }
            .disposed(by: rx.disposeBag)

        output.phaseText
            .driveOnNext { [weak self] text in
                self?.phaseLabel.stringValue = text
            }
            .disposed(by: rx.disposeBag)

        output.progressValue
            .driveOnNext { [weak self] value in
                self?.progressIndicator.doubleValue = value
            }
            .disposed(by: rx.disposeBag)

        output.currentObjectText
            .driveOnNext { [weak self] text in
                self?.objectLabel.stringValue = text
            }
            .disposed(by: rx.disposeBag)

        output.result
            .compactMap { $0 }
            .driveOnNext { [weak self] result in
                guard let self else { return }
                var lines: [String] = []
                lines.append("\(result.succeeded) interfaces exported successfully")
                if result.failed > 0 {
                    lines.append("\(result.failed) failed")
                }
                lines.append(String(format: "Duration: %.1fs", result.totalDuration))
                lines.append("ObjC: \(result.objcCount) | Swift: \(result.swiftCount)")
                summaryLabel.stringValue = lines.joined(separator: "\n")
            }
            .disposed(by: rx.disposeBag)

        output.requestDirectorySelection
            .emit(onNext: { [weak self] in
                self?.presentDirectoryPicker()
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
            guard let self, response == .OK, let url = panel.url else { return }
            viewModel?.startExport(to: url)
        }
    }
}
