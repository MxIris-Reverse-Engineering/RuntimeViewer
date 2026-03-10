import AppKit
import RuntimeViewerUI
import RuntimeViewerMCPBridge
import RuntimeViewerSettingsUI
import RxSwift
import RxCocoa

final class MCPStatusPopoverController: NSViewController {

    // MARK: - Views

    private let statusCircle = ImageView()
    private let statusLabel = Label()
    private let portTitleLabel = Label("Port:")
    private let portValueLabel = Label()
    private let copyPortButton = NSButton()
    private let actionButton = PushButton()

    // MARK: - State

    private var currentState: MCPServerState = .stopped
    private let stateRelay: BehaviorRelay<MCPServerState>
    private let disposeBag = DisposeBag()

    // MARK: - Init

    init(stateRelay: BehaviorRelay<MCPServerState>) {
        self.stateRelay = stateRelay
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = UXView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupViews()
        setupLayout()
        setupBindings()
    }

    // MARK: - Setup

    private func setupViews() {
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
            $0.target = self
            $0.action = #selector(copyPort)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }

        actionButton.do {
            $0.controlSize = .regular
            $0.target = self
            $0.action = #selector(actionButtonClicked)
        }
    }

    private func setupLayout() {
        let statusRow = HStackView(spacing: 6) {
            statusCircle
            statusLabel
        }

        let portRow = HStackView(spacing: 6) {
            portTitleLabel
            portValueLabel
            copyPortButton
        }

        let contentStack = VStackView(alignment: .leading, spacing: 10) {
            statusRow
            portRow
            actionButton
        }

        view.hierarchy {
            contentStack
        }

        contentStack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))
        }

        statusCircle.snp.makeConstraints { make in
            make.size.equalTo(10)
        }

        actionButton.snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(120)
        }
    }

    // MARK: - Bindings

    private func setupBindings() {
        stateRelay.asDriver()
            .driveOnNext { [weak self] state in
                guard let self else { return }
                updateUI(for: state)
            }
            .disposed(by: disposeBag)
    }

    // MARK: - UI Update

    private func updateUI(for state: MCPServerState) {
        currentState = state
        let circleImage = SFSymbols(name: SFSymbols.SystemSymbolName.circleFill).nsImage

        switch state {
        case .disabled:
            statusCircle.contentTintColor = .systemGray
            statusCircle.image = circleImage
            statusLabel.stringValue = "MCP Server Disabled"
            portTitleLabel.isHidden = true
            portValueLabel.isHidden = true
            copyPortButton.isHidden = true
            actionButton.title = "Open Settings…"

        case .stopped:
            statusCircle.contentTintColor = .systemRed
            statusCircle.image = circleImage
            statusLabel.stringValue = "MCP Server Stopped"
            portTitleLabel.isHidden = true
            portValueLabel.isHidden = true
            copyPortButton.isHidden = true
            actionButton.title = "Start Server"

        case .running(let port):
            statusCircle.contentTintColor = .systemGreen
            statusCircle.image = circleImage
            statusLabel.stringValue = "MCP Server Running"
            portTitleLabel.isHidden = false
            portValueLabel.isHidden = false
            portValueLabel.stringValue = "\(port)"
            copyPortButton.isHidden = false
            actionButton.title = "Stop Server"
        }
    }

    // MARK: - Actions

    @objc private func copyPort() {
        guard let port = currentState.port else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(port)", forType: .string)
    }

    @objc private func actionButtonClicked() {
        switch currentState {
        case .disabled:
            SettingsWindowController.shared.showWindow(nil)
        case .stopped:
            MCPService.shared.start(for: AppMCPBridgeDocumentProvider())
        case .running:
            MCPService.shared.stop()
        }
    }
}
