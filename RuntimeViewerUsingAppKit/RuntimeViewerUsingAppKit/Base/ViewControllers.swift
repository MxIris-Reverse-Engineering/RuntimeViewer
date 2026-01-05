import AppKit
import LateResponders
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

open class UXKitViewController<ViewModel: ViewModelProtocol>: UXViewController {
    public private(set) var viewModel: ViewModel?

    private let commonLoadingView = CommonLoadingView()

    public private(set) var contentView: NSView = UXView()

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
                make.edges.equalTo(view.safeAreaLayoutGuide)
            } else {
                make.edges.equalToSuperview()
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

open class UXEffectViewController<ViewModel: ViewModelProtocol>: UXKitViewController<ViewModel> {
    private lazy var effectView: NSView = {
        if #available(macOS 26.0, *) {
            let view = UXView()
//            view.backgroundColor = .windowBackgroundColor
            return view
        } else {
            return NSVisualEffectView()
        }
    }()

    open override var contentView: NSView { effectView }

    open override func viewDidLoad() {
        super.viewDidLoad()
    }
}

open class AppKitViewController<ViewModel: ViewModelProtocol>: NSViewController {
    public private(set) var viewModel: ViewModel?

    public init(viewModel: ViewModel? = nil) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    open func setupBindings(for viewModel: ViewModel) {
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


open class UXKitNavigationController: UXNavigationController {
    
    open var shouldUseNoAnimationTransition: Bool { false }
    
    open override func viewDidLoad() {
        super.viewDidLoad()

        isToolbarHidden = true
        isNavigationBarHidden = true
        delegate = self
    }
}

extension UXKitNavigationController: UXNavigationControllerDelegate {
    public func navigationController(_ navigationController: UXNavigationController, animationControllerFor operation: UXNavigationController.Operation, from fromViewController: UXViewController, to toViewController: UXViewController) -> (any UXViewControllerAnimatedTransitioning)? {
        guard shouldUseNoAnimationTransition else { return nil }
        return UXKitNoAnimationTransition.shared
    }
}

private final class UXKitNoAnimationTransition: NSObject, UXViewControllerAnimatedTransitioning {

    private override init() {}
    
    static let shared = UXKitNoAnimationTransition()
    
    func transitionDuration(using transitionContext: UXViewControllerContextTransitioning?) -> TimeInterval {
        return 0
    }

    func animateTransition(using transitionContext: UXViewControllerContextTransitioning) {
        let containerView = transitionContext.containerView
        
        guard let toVC = transitionContext.viewController(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }
        
        let toView = toVC.view
        
        let finalFrame = transitionContext.finalFrame(for: toVC)
        if finalFrame != .zero {
            toView.frame = finalFrame
        }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        containerView.addSubview(toView)
        toView.layoutSubtreeIfNeeded()
        
        CATransaction.commit()
        
        transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
    }
}
