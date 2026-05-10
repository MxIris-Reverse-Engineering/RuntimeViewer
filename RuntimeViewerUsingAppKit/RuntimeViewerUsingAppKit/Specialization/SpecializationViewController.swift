import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import SnapKit

final class SpecializationViewController: UXKitViewController<SpecializationViewModel> {
    // MARK: - Subviews

    private let headerLabel = Label()
    private let statusLabel = Label()
    private let gridView = NSGridView().then {
        $0.rowSpacing = 8
        $0.columnSpacing = 12
        $0.xPlacement = .leading
        $0.yPlacement = .center
    }
    private let cancelButton = PushButton(title: "Cancel", titleFont: .systemFont(ofSize: 13))
    private let specializeButton = PushButton(title: "Specialize", titleFont: .systemFont(ofSize: 13))

    /// Map from parameter name → its choose button. Used by
    /// `anchorView(forParameter:)` so the coordinator can present the
    /// type-picker popover relative to the right per-row button, and by the
    /// `selection` driver to refresh the button title in place.
    private var chooseButtonsByParameterName: [String: NSButton] = [:]

    /// Aggregator for "Choose Type" clicks across the dynamically rebuilt
    /// rows. Each row's `chooseButton` accepts its parameter name into this
    /// relay; the relay's signal is wired through `Input` so the VM sees a
    /// single per-parameter click stream.
    private let requestTypePickerClickedRelay = PublishRelay<String>()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        view.hierarchy {
            headerLabel
            statusLabel
            gridView
            cancelButton
            specializeButton
        }

        headerLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(20)
        }

        gridView.snp.makeConstraints { make in
            make.top.equalTo(headerLabel.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(20)
        }

        statusLabel.snp.makeConstraints { make in
            make.top.equalTo(headerLabel.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(20)
        }

        specializeButton.snp.makeConstraints { make in
            make.top.greaterThanOrEqualTo(gridView.snp.bottom).offset(20)
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

        preferredContentSize = NSSize(width: 480, height: 360)
    }

    // MARK: - Anchor lookup (for coordinator-driven popover positioning)

    func anchorView(forParameter parameterName: String) -> NSView? {
        chooseButtonsByParameterName[parameterName]
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: SpecializationViewModel) {
        super.setupBindings(for: viewModel)

        let input = SpecializationViewModel.Input(
            specializeClicked: specializeButton.rx.click.asSignal(),
            cancelClicked: cancelButton.rx.click.asSignal(),
            requestTypePickerClicked: requestTypePickerClickedRelay.asSignal()
        )
        let output = viewModel.transform(input)

        output.runtimeObjectDisplayName
            .map { "Specialize \($0)" }
            .drive(headerLabel.rx.stringValue)
            .disposed(by: rx.disposeBag)

        output.canSpecialize.drive(specializeButton.rx.isEnabled).disposed(by: rx.disposeBag)

        let loadState = output.loadState
        loadState.map(Self.statusText).drive(statusLabel.rx.stringValue).disposed(by: rx.disposeBag)
        loadState.map(Self.isStatusHidden).drive(statusLabel.rx.isHidden).disposed(by: rx.disposeBag)
        loadState.map(Self.isFormHidden).drive(gridView.rx.isHidden).disposed(by: rx.disposeBag)
        loadState.map(Self.isSpecializeHidden).drive(specializeButton.rx.isHidden).disposed(by: rx.disposeBag)

        output.request.driveOnNext { [weak self] request in
            guard let self else { return }
            rebuildForm(for: request)
        }
        .disposed(by: rx.disposeBag)

        output.selection.driveOnNext { [weak self] selection in
            guard let self else { return }
            for (parameterName, chooseButton) in chooseButtonsByParameterName {
                chooseButton.title = selection[parameterName]?.displayName ?? "Choose Type…"
            }
        }
        .disposed(by: rx.disposeBag)
    }

    // MARK: - Load state helpers

    private static func statusText(_ state: SpecializationViewModel.LoadState) -> String {
        switch state {
        case .idle, .loading: return "Loading…"
        case .loaded: return ""
        case .unsupported(let reason): return reason
        case .failed(let message): return message
        }
    }

    private static func isStatusHidden(_ state: SpecializationViewModel.LoadState) -> Bool {
        if case .loaded = state { return true }
        return false
    }

    private static func isFormHidden(_ state: SpecializationViewModel.LoadState) -> Bool {
        if case .loaded = state { return false }
        return true
    }

    private static func isSpecializeHidden(_ state: SpecializationViewModel.LoadState) -> Bool {
        switch state {
        case .idle, .loading, .loaded: return false
        case .unsupported, .failed: return true
        }
    }

    // MARK: - Form

    private func rebuildForm(for request: RuntimeSpecializationRequest?) {
        while gridView.numberOfRows > 0 {
            gridView.removeRow(at: 0)
        }
        chooseButtonsByParameterName.removeAll()

        guard let request else { return }

        for parameter in request.parameters {
            let nameLabel = Label(parameter.displayDescription).then {
                $0.font = .systemFont(ofSize: 13)
                $0.textColor = .controlTextColor
            }
            nameLabel.setContentHuggingPriority(.required, for: .horizontal)

            let chooseButton = PushButton(title: "Choose Type…", titleFont: .systemFont(ofSize: 13))
            chooseButton.snp.makeConstraints { make in
                make.width.greaterThanOrEqualTo(180)
            }

            chooseButton.rx.click
                .asSignal()
                .emit(with: self) { $0.requestTypePickerClickedRelay.accept(parameter.name) }
                .disposed(by: chooseButton.rx.disposeBag)

            gridView.addRow(with: [nameLabel, chooseButton])
            chooseButtonsByParameterName[parameter.name] = chooseButton
        }

        // Columns are created lazily by `addRow(with:)` — only configure them
        // after the first row has been added, otherwise `column(at:)` traps.
        if gridView.numberOfColumns >= 2 {
            gridView.column(at: 0).xPlacement = .leading
            gridView.column(at: 1).xPlacement = .trailing
        }
    }
}
