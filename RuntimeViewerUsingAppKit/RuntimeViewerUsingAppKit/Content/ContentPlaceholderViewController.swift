import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ContentPlaceholderViewController: BaseViewController<ContentPlaceholderViewModel> {
    private let readingIndicator = NSProgressIndicator().then {
        $0.style = .spinning
        $0.controlSize = .regular
        $0.isDisplayedWhenStopped = false
    }

    private let placeholderLabel = Label("Select a runtime object")

    override var containerViewUsingSafeArea: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()

        let stackView = VStackView(alignment: .center, spacing: 12) {
            readingIndicator
            placeholderLabel
        }

        containerView.hierarchy {
            stackView
        }

        stackView.snp.makeConstraints { make in
            make.center.equalTo(containerView)
        }

        placeholderLabel.do {
            $0.font = .systemFont(ofSize: 20, weight: .regular)
            $0.textColor = .secondaryLabelColor
        }
    }

    override func setupBindings(for viewModel: ContentPlaceholderViewModel) {
        super.setupBindings(for: viewModel)

        let output = viewModel.transform(.init())

        output.placeholder.driveOnNext { [weak self] placeholder in
            guard let self else { return }
            switch placeholder {
            case .noSelection:
                placeholderLabel.stringValue = "Select a runtime object"
                readingIndicator.stopAnimation(nil)
            case .readingFile(let name):
                placeholderLabel.stringValue = "Reading “\(name)”…"
                readingIndicator.startAnimation(nil)
            }
        }
        .disposed(by: rx.disposeBag)
    }
}
