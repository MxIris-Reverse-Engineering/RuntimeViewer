import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerMCPBridge
import RuntimeViewerSettingsUI

final class MCPStatusPopoverViewController: AppKitViewController<MCPStatusPopoverViewModel<MainRoute>> {
    // MARK: - Views

    private let statusCircle = ImageView()
    private let statusLabel = Label()
    private let portTitleLabel = Label("Port:")
    private let portValueLabel = Label()
    private let copyPortButton = NSButton()
    private let actionButton = PushButton()

    private let configTitleLabel = Label("Copy Install Command:")
    private let claudeCodeButton = NSButton()
    private let codexButton = NSButton()
    private let jsonButton = NSButton()

    private lazy var statusRow = HStackView(spacing: 6) {
        statusCircle
        statusLabel
    }

    private lazy var portRow = HStackView(spacing: 6) {
        portTitleLabel
        portValueLabel
        copyPortButton
    }

    private lazy var configButtonRow = HStackView(spacing: 6) {
        claudeCodeButton
        codexButton
        jsonButton
    }

    private lazy var configSection = VStackView(alignment: .leading, spacing: 6) {
        configTitleLabel
        configButtonRow
    }

    private lazy var contentStack = VStackView(alignment: .leading, spacing: 10) {
        statusRow
        portRow
        configSection
        actionButton
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            contentStack
        }

        contentStack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(16)
        }

        statusCircle.snp.makeConstraints { make in
            make.size.equalTo(10)
        }

        actionButton.snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(120)
        }

        statusCircle.do {
            $0.imageScaling = .scaleProportionallyDown
        }

        statusLabel.do {
            $0.font = .systemFont(ofSize: 13, weight: .semibold)
            $0.textColor = .labelColor
        }

        portTitleLabel.do {
            $0.font = .systemFont(ofSize: 12)
            $0.textColor = .secondaryLabelColor
        }

        portValueLabel.do {
            $0.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            $0.textColor = .labelColor
        }

        copyPortButton.do {
            $0.image = SFSymbols(name: SFSymbols.SystemSymbolName.docOnDoc).nsImage
            $0.bezelStyle = .accessoryBarAction
            $0.isBordered = true
            $0.toolTip = "Copy Port"
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }

        actionButton.do {
            $0.controlSize = .regular
        }

        configTitleLabel.do {
            $0.font = .systemFont(ofSize: 11, weight: .medium)
            $0.textColor = .secondaryLabelColor
        }

        let copyImage = SFSymbols(name: SFSymbols.SystemSymbolName.docOnDoc).nsImage

        claudeCodeButton.do {
            $0.title = "Claude Code"
            $0.image = copyImage
            $0.imagePosition = .imageTrailing
            $0.bezelStyle = .accessoryBarAction
            $0.isBordered = true
            $0.font = .systemFont(ofSize: 11)
            $0.toolTip = "Copy claude mcp add command"
        }

        codexButton.do {
            $0.title = "Codex"
            $0.image = copyImage
            $0.imagePosition = .imageTrailing
            $0.bezelStyle = .accessoryBarAction
            $0.isBordered = true
            $0.font = .systemFont(ofSize: 11)
            $0.toolTip = "Copy codex mcp add command"
        }

        jsonButton.do {
            $0.title = "JSON"
            $0.image = copyImage
            $0.imagePosition = .imageTrailing
            $0.bezelStyle = .accessoryBarAction
            $0.isBordered = true
            $0.font = .systemFont(ofSize: 11)
            $0.toolTip = "Copy generic MCP JSON configuration"
        }

        preferredContentSize = view.fittingSize
    }

    private func updateUI(for state: MCPServerState) {
        let circleImage = SFSymbols(name: SFSymbols.SystemSymbolName.circleFill).nsImage

        switch state {
        case .disabled:
            statusCircle.contentTintColor = .systemGray
            statusCircle.image = circleImage
            statusLabel.stringValue = "MCP Server Disabled"
            portRow.isHidden = true
            configSection.isHidden = true
            actionButton.title = "Open Settings…"

        case .stopped:
            statusCircle.contentTintColor = .systemRed
            statusCircle.image = circleImage
            statusLabel.stringValue = "MCP Server Stopped"
            portRow.isHidden = true
            configSection.isHidden = true
            actionButton.title = "Start Server"

        case .running(let port):
            statusCircle.contentTintColor = .systemGreen
            statusCircle.image = circleImage
            statusLabel.stringValue = "MCP Server Running"
            portRow.isHidden = false
            configSection.isHidden = false
            portValueLabel.stringValue = "\(port)"
            actionButton.title = "Stop Server"
        }
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: MCPStatusPopoverViewModel<MainRoute>) {
        super.setupBindings(for: viewModel)

        let copyConfigSignal = Signal.merge(
            claudeCodeButton.rx.click.asSignal().map { MCPConfigType.claudeCode },
            codexButton.rx.click.asSignal().map { MCPConfigType.codex },
            jsonButton.rx.click.asSignal().map { MCPConfigType.json }
        )

        let input = MCPStatusPopoverViewModel<MainRoute>.Input(
            actionButtonClick: actionButton.rx.click.asSignal(),
            copyPortClick: copyPortButton.rx.click.asSignal(),
            copyConfig: copyConfigSignal
        )

        let output = viewModel.transform(input)

        output.state.driveOnNext { [weak self] state in
            guard let self else { return }
            updateUI(for: state)
        }
        .disposed(by: rx.disposeBag)

        output.openSettings.emitOnNext {
            SettingsWindowController.shared.showWindow(nil)
        }
        .disposed(by: rx.disposeBag)
    }
}
