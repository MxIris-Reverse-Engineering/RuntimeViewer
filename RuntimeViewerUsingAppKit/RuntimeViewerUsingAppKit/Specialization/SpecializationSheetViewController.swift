import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import SnapKit

final class SpecializationSheetViewController: AppKitViewController<SpecializationSheetViewModel> {

    // MARK: - Relays

    private let cancelClickedRelay = PublishRelay<Void>()
    private let specializeClickedRelay = PublishRelay<Void>()

    // MARK: - Subviews

    private let headerLabel = Label()
    private let statusLabel = Label()
    private let formContainer = NSView()
    private let formStack = VStackView(alignment: .leading, spacing: 8) {}
    private let cancelButton = PushButton(title: "Cancel", titleFont: .systemFont(ofSize: 13))
    private let specializeButton = PushButton(title: "Specialize", titleFont: .systemFont(ofSize: 13))

    /// Map from parameter name → row view, used by `anchorView(forParameter:)`
    /// so the coordinator can present the type-picker popover relative to
    /// the right per-row choose-button.
    private var rowViewsByParameterName: [String: ParameterRowView] = [:]

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        view.hierarchy {
            headerLabel
            statusLabel
            formContainer
            cancelButton
            specializeButton
        }

        formContainer.hierarchy {
            formStack
        }

        headerLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(20)
        }

        formContainer.snp.makeConstraints { make in
            make.top.equalTo(headerLabel.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(20)
        }

        formStack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        statusLabel.snp.makeConstraints { make in
            make.top.equalTo(headerLabel.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(20)
        }

        specializeButton.snp.makeConstraints { make in
            make.top.greaterThanOrEqualTo(formContainer.snp.bottom).offset(20)
            make.top.greaterThanOrEqualTo(statusLabel.snp.bottom).offset(20)
            make.trailing.bottom.equalToSuperview().inset(20)
            make.width.equalTo(100)
        }

        cancelButton.snp.makeConstraints { make in
            make.centerY.equalTo(specializeButton)
            make.trailing.equalTo(specializeButton.snp.leading).offset(-12)
            make.width.equalTo(100)
        }

        headerLabel.do {
            $0.font = .systemFont(ofSize: 18, weight: .semibold)
            $0.textColor = .controlTextColor
        }

        statusLabel.do {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .secondaryLabelColor
            $0.maximumNumberOfLines = 0
            $0.lineBreakMode = .byWordWrapping
        }

        specializeButton.do {
            $0.keyEquivalent = "\r"
            $0.isEnabled = false
        }

        cancelButton.do {
            $0.keyEquivalent = "\u{1b}"
        }

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        specializeButton.target = self
        specializeButton.action = #selector(specializeClicked)

        preferredContentSize = NSSize(width: 480, height: 360)
    }

    // MARK: - Actions

    @objc private func cancelClicked() {
        cancelClickedRelay.accept(())
    }

    @objc private func specializeClicked() {
        specializeClickedRelay.accept(())
    }

    // MARK: - Anchor lookup (for coordinator-driven popover positioning)

    func anchorView(forParameter parameterName: String) -> NSView? {
        rowViewsByParameterName[parameterName]?.chooseButton
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: SpecializationSheetViewModel) {
        super.setupBindings(for: viewModel)

        let input = SpecializationSheetViewModel.Input(
            specializeClicked: specializeClickedRelay.asSignal(),
            cancelClicked: cancelClickedRelay.asSignal()
        )
        let output = viewModel.transform(input)

        output.runtimeObjectDisplayName.driveOnNext { [weak self] name in
            guard let self else { return }
            headerLabel.stringValue = "Specialize \(name)"
        }
        .disposed(by: rx.disposeBag)

        output.canSpecialize.drive(specializeButton.rx.isEnabled).disposed(by: rx.disposeBag)

        output.loadState.driveOnNext { [weak self] state in
            guard let self else { return }
            applyLoadState(state)
        }
        .disposed(by: rx.disposeBag)

        output.request.driveOnNext { [weak self, weak viewModel] request in
            guard let self, let viewModel else { return }
            rebuildForm(for: request, viewModel: viewModel)
        }
        .disposed(by: rx.disposeBag)

        output.selection.driveOnNext { [weak self] selection in
            guard let self else { return }
            for (parameterName, row) in rowViewsByParameterName {
                row.updateArgument(selection[parameterName])
            }
        }
        .disposed(by: rx.disposeBag)
    }

    // MARK: - Load state rendering

    private func applyLoadState(_ state: SpecializationSheetViewModel.LoadState) {
        switch state {
        case .idle, .loading:
            statusLabel.stringValue = "Loading…"
            statusLabel.isHidden = false
            formContainer.isHidden = true
            specializeButton.isHidden = false
        case .loaded:
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
            formContainer.isHidden = false
            specializeButton.isHidden = false
        case .unsupported(let reason):
            statusLabel.stringValue = reason
            statusLabel.isHidden = false
            formContainer.isHidden = true
            specializeButton.isHidden = true
        case .failed(let message):
            statusLabel.stringValue = message
            statusLabel.isHidden = false
            formContainer.isHidden = true
            specializeButton.isHidden = true
        }
    }

    private func rebuildForm(
        for request: RuntimeSpecializationRequest?,
        viewModel: SpecializationSheetViewModel
    ) {
        formStack.arrangedSubviews.forEach {
            formStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rowViewsByParameterName.removeAll()
        guard let request else { return }
        for parameter in request.parameters {
            let row = ParameterRowView(parameter: parameter)
            row.requestTypePicker = { [weak viewModel] parameterName in
                viewModel?.requestTypePickerClickedRelay.accept(parameterName)
            }
            formStack.addArrangedSubview(row)
            rowViewsByParameterName[parameter.name] = row
        }
    }
}

// MARK: - ParameterRowView

extension SpecializationSheetViewController {
    fileprivate final class ParameterRowView: NSView {
        let parameter: RuntimeSpecializationRequest.Parameter
        let nameLabel = Label()
        let chooseButton = PushButton(title: "Choose Type…", titleFont: .systemFont(ofSize: 13))
        var requestTypePicker: ((String) -> Void)?

        init(parameter: RuntimeSpecializationRequest.Parameter) {
            self.parameter = parameter
            super.init(frame: .zero)

            hierarchy {
                nameLabel
                chooseButton
            }

            nameLabel.snp.makeConstraints { make in
                make.leading.centerY.equalToSuperview()
                make.width.greaterThanOrEqualTo(120)
            }

            chooseButton.snp.makeConstraints { make in
                make.leading.equalTo(nameLabel.snp.trailing).offset(12)
                make.trailing.centerY.equalToSuperview()
                make.top.bottom.equalToSuperview().inset(2)
                make.width.greaterThanOrEqualTo(180)
            }

            nameLabel.do {
                $0.font = .systemFont(ofSize: 13)
                $0.textColor = .controlTextColor
                $0.stringValue = parameter.displayDescription
            }

            chooseButton.target = self
            chooseButton.action = #selector(chooseClicked)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func chooseClicked() {
            requestTypePicker?(parameter.name)
        }

        func updateArgument(_ candidate: RuntimeSpecializationRequest.Candidate?) {
            chooseButton.title = candidate?.displayName ?? "Choose Type…"
        }
    }
}
