import AppKit
import RuntimeViewerApplication
import RuntimeViewerUI
import RuntimeViewerArchitectures

class UXKitViewController<ViewModel: ViewModelProtocol>: UXViewController {
    var viewModel: ViewModel?

    private let commonLoadingView = CommonLoadingView()

    var shouldDisplayCommonLoading: Bool { false }

    private(set) var contentView: NSView = UXView()

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
        
        viewModel.errorRelay
            .asSignal()
            .emitOnNextMainActor { [weak self] error in
                guard let self else { return }
                if let window = view.window {
                    NSAlert(error: error).beginSheetModal(for: window)
                } else {
                    NSAlert(error: error).runModal()
                }
            }
            .disposed(by: rx.disposeBag)
    }
}

class UXEffectViewController<ViewModel: ViewModelProtocol>: UXKitViewController<ViewModel> {
    private lazy var effectView: NSView = {
        if #available(macOS 26.0, *) {
            let view = UXView()
//            view.backgroundColor = .windowBackgroundColor
            return view
        } else {
            return NSVisualEffectView()
        }
    }()

    override var contentView: NSView { effectView }

    override func viewDidLoad() {
        super.viewDidLoad()
    }
}

class AppKitViewController<ViewModel: ViewModelProtocol>: NSViewController {
    var viewModel: ViewModel?

    init(viewModel: ViewModel? = nil) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setupBindings(for viewModel: ViewModel) {
        rx.disposeBag = DisposeBag()
        self.viewModel = viewModel
        
        
        viewModel.errorRelay
            .asSignal()
            .emitOnNextMainActor { [weak self] error in
                guard let self else { return }
                if let window = view.window {
                    NSAlert(error: error).beginSheetModal(for: window)
                } else {
                    NSAlert(error: error).runModal()
                }
            }
            .disposed(by: rx.disposeBag)
    }
}
