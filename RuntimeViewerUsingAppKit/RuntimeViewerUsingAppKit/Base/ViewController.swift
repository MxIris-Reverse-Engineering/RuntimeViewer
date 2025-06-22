import AppKit
import RuntimeViewerApplication
import RuntimeViewerUI
import RuntimeViewerArchitectures

class UXKitViewController<ViewModel: ViewModelProtocol>: UXViewController {
    var viewModel: ViewModel?

    private let commonLoadingView = CommonLoadingView()

    var shouldDisplayCommonLoading: Bool { false }

    private(set) var contentView = NSView()

    init(viewModel: ViewModel? = nil) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            contentView
            if shouldDisplayCommonLoading {
                commonLoadingView
            }
        }

        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        if shouldDisplayCommonLoading {
            commonLoadingView.snp.makeConstraints { make in
                make.edges.equalTo(view.safeAreaLayoutGuide)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setupBindings(for viewModel: ViewModel) {
        rx.disposeBag = DisposeBag()
        self.viewModel = viewModel
        if shouldDisplayCommonLoading {
            viewModel.commonLoading.drive(commonLoadingView.rx.isRunning).disposed(by: rx.disposeBag)
        }
    }
}

class UXVisualEffectViewController<ViewModel: ViewModelProtocol>: UXKitViewController<ViewModel> {
    private let visualEffectView = NSVisualEffectView()

    override var contentView: NSView { visualEffectView }

    override func viewDidLoad() {
        super.viewDidLoad()
    }
}

class AppKitViewController<ViewModelType>: NSViewController {
    var viewModel: ViewModelType?

    init(viewModel: ViewModelType? = nil) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setupBindings(for viewModel: ViewModelType) {
        rx.disposeBag = DisposeBag()
        self.viewModel = viewModel
    }
}
