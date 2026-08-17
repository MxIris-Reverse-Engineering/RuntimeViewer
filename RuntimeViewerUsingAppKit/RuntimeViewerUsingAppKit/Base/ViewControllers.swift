import AppKit
import LateResponders
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

open class AppKitViewController<ViewModel: ViewModelProtocol>: NSViewController {
    public private(set) var viewModel: ViewModel?

    private let commonLoadingView = CommonLoadingView()

    public private(set) var contentView: NSView = LayerBackedView()

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

    /// **Load-bearing.** `UXViewController` used to supply this; `NSViewController`'s own
    /// `loadView` looks up a nib named after the class, which this project does not ship, so
    /// without it every subclass traps on first view access.
    open override func loadView() {
        view = LayerBackedView()
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

open class EffectViewController<ViewModel: ViewModelProtocol>: AppKitViewController<ViewModel> {
    private lazy var effectView: NSView = {
        if #available(macOS 26.0, *) {
            return LayerBackedView()
        } else {
            return NSVisualEffectView()
        }
    }()

    open override var contentView: NSView { effectView }
}

/// The project's navigation container.
///
/// `NavigationController` has no navigation bar and no toolbar, which is what this class used to
/// spend its `viewDidLoad` switching off on `UXNavigationController` — and switching them off did
/// not stop UXKit from laying the bar out on every push. See proposal 0012.
///
/// Interactive pop stays off for the same reason it was off before: the panes are driven by the
/// coordinator's route, and a swipe that pops the stack behind the router's back desynchronises
/// the two.
open class BaseNavigationController: NavigationController {
    open override func viewDidLoad() {
        super.viewDidLoad()

        allowsInteractivePop = false
    }
}
