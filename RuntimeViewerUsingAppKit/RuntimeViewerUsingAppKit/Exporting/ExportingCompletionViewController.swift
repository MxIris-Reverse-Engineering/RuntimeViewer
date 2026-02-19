import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingCompletionViewController: AppKitViewController<ExportingCompletionViewModel>, ExportingStepViewController {
    private let checkmarkImageView = NSImageView().then {
        $0.image = .symbol(systemName: .checkmarkCircleFill)
        $0.symbolConfiguration = .init(pointSize: 56, weight: .regular)
        $0.contentTintColor = .systemGreen
    }

    private let titleLabel = Label("Export Complete").then {
        $0.font = .systemFont(ofSize: 20, weight: .bold)
        $0.alignment = .center
    }

    private let summaryLabel = Label().then {
        $0.font = .systemFont(ofSize: 13)
        $0.textColor = .secondaryLabelColor
        $0.alignment = .center
        $0.maximumNumberOfLines = 0
        $0.preferredMaxLayoutWidth = 350
    }

    private let showInFinderButton = PushButton().then {
        $0.title = "Show in Finder"
    }

    private lazy var contentStackView = VStackView(distribution: .fill, spacing: 10) {
        checkmarkImageView
            .customSpacing(24)
        titleLabel
        summaryLabel
            .customSpacing(16)
        showInFinderButton
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            contentStackView
        }

        contentStackView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.top.leading.greaterThanOrEqualToSuperview()
            make.bottom.trailing.lessThanOrEqualToSuperview()
        }
    }

    override func setupBindings(for viewModel: ExportingCompletionViewModel) {
        super.setupBindings(for: viewModel)

        let input = ExportingCompletionViewModel.Input(
            refresh: rx.viewDidAppear.asSignal(),
            showInFinderClick: showInFinderButton.rx.click.asSignal()
        )

        let output = viewModel.transform(input)

        output.summaryText.drive(summaryLabel.rx.stringValue).disposed(by: rx.disposeBag)
    }
}

final class MockRouter<Route: Routable>: NSObject, Router {
    var triggeredRoutes: [Route] = []

    func contextTrigger(_ route: Route, with options: TransitionOptions, completion: ContextPresentationHandler?) {
        triggeredRoutes.append(route)
        completion?(AppTransition.none())
    }
}

#Preview(traits: .fixedLayout(width: 750, height: 450)) {
    let mockRouter = MockRouter<ExportingRoute>()
    let viewModel = ExportingCompletionViewModel(exportingState: .completionStepTesting, documentState: .init(), router: mockRouter)
    let viewController = ExportingCompletionViewController()
    viewController.setupBindings(for: viewModel)
    return viewController
}
