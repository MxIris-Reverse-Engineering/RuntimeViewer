import AppKit
import AppKitPlus
import LateResponders
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

/// `NSViewController`-based VM-hosting base for every AppKit view controller in the app.
///
/// The stack of `NSNavigationController` takes plain `NSViewController`s, so there is no base
/// class to adopt for navigation — this one exists only to carry the ViewModel plumbing
/// (`viewModel`, `setupBindings(for:)`, `errorRelay` alert presentation) plus the `contentView` /
/// loading-indicator / skeleton machinery the panes share.
open class BaseViewController<ViewModel: ViewModelProtocol>: NSViewController {
    public private(set) var viewModel: ViewModel?

    private let commonLoadingView = CommonLoadingView()

    public private(set) var contentView: NSView = NSView()

    open var contentInsets: NSDirectionalEdgeInsets { .init() }

    open var shouldDisplayCommonLoading: Bool { false }

    open var contentViewUsingSafeArea: Bool { false }

    private var usesSkeletonReplaceCommonLoading: Bool { false }

    private var _shouldSetupCommonLoading: Bool {
        shouldDisplayCommonLoading && !usesSkeletonReplaceCommonLoading
    }

    public init(viewModel: ViewModel? = nil) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    open override func loadView() {
        // Default to an empty `NSView`; subclasses install their content hierarchy inside
        // `viewDidLoad`. `NSViewController`'s own `loadView` would look up a nib by class name,
        // which we don't ship. `UXViewController` used to supply this.
        view = NSView()
    }

    open override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            contentView
            if _shouldSetupCommonLoading {
                commonLoadingView
            }
        }

        contentView.snp.makeConstraints { make in
            if contentViewUsingSafeArea {
                make.top.equalTo(view.safeAreaLayoutGuide).inset(contentInsets.top)
                make.leading.equalTo(view.safeAreaLayoutGuide).inset(contentInsets.leading)
                make.trailing.equalTo(view.safeAreaLayoutGuide).inset(contentInsets.trailing)
                make.bottom.equalTo(view.safeAreaLayoutGuide).inset(contentInsets.bottom)
            } else {
                make.top.equalToSuperview().inset(contentInsets.top)
                make.leading.equalToSuperview().inset(contentInsets.leading)
                make.trailing.equalToSuperview().inset(contentInsets.trailing)
                make.bottom.equalToSuperview().inset(contentInsets.bottom)
            }
        }

        if _shouldSetupCommonLoading {
            commonLoadingView.snp.makeConstraints { make in
                make.edges.equalTo(view.safeAreaLayoutGuide)
            }
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    open func setupBindings(for viewModel: ViewModel) {
        loadViewIfNeeded()

        rx.disposeBag = DisposeBag()

        self.viewModel = viewModel

        if shouldDisplayCommonLoading {
            if usesSkeletonReplaceCommonLoading {
                viewModel.delayedLoading.driveOnNextMainActor { [weak self] isLoading in
                    guard let self else { return }
                    if isLoading {
                        contentView.showSkeleton()
                    } else {
                        contentView.hideSkeleton()
                    }
                }
                .disposed(by: rx.disposeBag)
            } else {
                viewModel.delayedLoading.drive(commonLoadingView.rx.isRunning).disposed(by: rx.disposeBag)
            }
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

    open override func viewDidAppear() {
        super.viewDidAppear()

        registerLateResponders()
    }

    open override func viewDidDisappear() {
        super.viewDidDisappear()

        unregisterLateResponders()
    }

    open func lateResponderSelectors() -> [Selector] { [] }

    private var lateResponder: LateResponder?

    private func registerLateResponders() {
        let lateResponderSelectors = lateResponderSelectors()
        guard !lateResponderSelectors.isEmpty else { return }
        guard let registry = lateResponderRegistering()?.lateResponderRegistry else { return }
        lateResponder?.deregister()
        let proxy = LateResponderProxy(for: self)
        proxy.proxiedSelectorNames = lateResponderSelectors.map { NSStringFromSelector($0) }
        registry.register(proxy)
        lateResponder = proxy
    }

    private func unregisterLateResponders() {
        guard let lateResponder else { return }
        lateResponder.deregister()
        self.lateResponder = nil
    }
}

open class BaseEffectViewController<ViewModel: ViewModelProtocol>: BaseViewController<ViewModel> {
    private lazy var effectView: NSView = {
        if #available(macOS 26.0, *) {
            return NSView()
//            view.backgroundColor = .windowBackgroundColor
        } else {
            return NSVisualEffectView()
        }
    }()

    open override var contentView: NSView { effectView }
}

open class BaseNavigationController: NSNavigationController {
    open override func viewDidLoad() {
        super.viewDidLoad()

        isToolbarHidden = true
        isNavigationBarHidden = true
        interactivePopGestureRecognizer?.isEnabled = false
    }
}
