import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingProgressViewController: AppKitViewController<ExportingProgressViewModel>, ExportingStepViewController {
    private let progressPhaseLabel = Label("Preparing...").then {
        $0.font = .systemFont(ofSize: 20, weight: .bold)
        $0.textColor = .controlTextColor
        $0.alignment = .center
    }

    private let progressIndicator = NSProgressIndicator().then {
        $0.style = .bar
        $0.isIndeterminate = false
        $0.minValue = 0
        $0.maxValue = 1
    }

    private let progressObjectLabel = Label().then {
        $0.font = .systemFont(ofSize: 13)
        $0.textColor = .secondaryLabelColor
        $0.alignment = .center
        $0.lineBreakMode = .byTruncatingMiddle
        $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        hierarchy {
            progressPhaseLabel
            progressIndicator
            progressObjectLabel
        }
        
        progressIndicator.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(100)
        }
        
        progressPhaseLabel.snp.makeConstraints { make in
            make.bottom.equalTo(progressIndicator.snp.top).offset(-8)
            make.leading.trailing.equalTo(progressIndicator)
        }
        
        progressObjectLabel.snp.makeConstraints { make in
            make.top.equalTo(progressIndicator.snp.bottom).offset(8)
            make.leading.trailing.equalTo(progressIndicator)
        }
    }

    override func setupBindings(for viewModel: ExportingProgressViewModel) {
        super.setupBindings(for: viewModel)

        let input = ExportingProgressViewModel.Input(
            startExport: rx.viewDidAppear.asSignal()
        )

        let output = viewModel.transform(input)

        output.phaseText.drive(progressPhaseLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.progressValue.drive(progressIndicator.rx.doubleValue).disposed(by: rx.disposeBag)

        output.currentObjectText.drive(progressObjectLabel.rx.stringValue).disposed(by: rx.disposeBag)
    }
}
