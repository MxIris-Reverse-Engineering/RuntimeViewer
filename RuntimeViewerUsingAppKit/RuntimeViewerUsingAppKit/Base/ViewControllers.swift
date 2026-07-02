import AppKit
import LateResponders
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

open class UXKitViewController<ViewModel: ViewModelProtocol>: UXViewController {
    public private(set) var viewModel: ViewModel?

    private let commonLoadingView = CommonLoadingView()

    public private(set) var contentView: NSView = UXView()

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

/// Plain `NSViewController`-based VM-hosting base. Use this when the view
/// controller cannot inherit from `UXViewController` — most notably for
/// popover content, since `UXViewController` overrides `preferredContentSize`
/// with a private ivar that doesn't forward to `NSViewController`, breaking
/// plain `NSPopover`'s KVO-driven resize observer. `UXKitViewController`
/// works around that with `UXPopoverController`, but the bridge KVOs
/// `preferredContentSize` on the controller and re-emits intermediate values
/// to `NSPopover.contentSize` whenever the property is animated inside an
/// `NSAnimationContext`, producing visible glitches (e.g. the popover
/// collapsing to zero before growing to target).
///
/// This base mirrors `UXKitViewController`'s API surface (`viewModel`,
/// `setupBindings(for:)`, `errorRelay` alert presentation) without the
/// `contentView` / loading-indicator / skeleton machinery — popovers
/// don't need any of that and the simpler base keeps the popover's
/// `preferredContentSize` flowing through standard AppKit channels.
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

    open override func loadView() {
        // Default to an empty `NSView`; subclasses install their content
        // hierarchy inside `viewDidLoad`. NSViewController's default
        // `loadView` would look up a nib by class name, which we don't ship.
        view = NSView()
    }

    open func setupBindings(for viewModel: ViewModel) {
        loadViewIfNeeded()

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

open class UXEffectViewController<ViewModel: ViewModelProtocol>: UXKitViewController<ViewModel> {
    private lazy var effectView: NSView = {
        if #available(macOS 26.0, *) {
            return UXView()
//            view.backgroundColor = .windowBackgroundColor
        } else {
            return NSVisualEffectView()
        }
    }()

    open override var contentView: NSView { effectView }
}

open class UXKitNavigationController: UXNavigationController {
    open override func viewDidLoad() {
        super.viewDidLoad()

        isToolbarHidden = true
        isNavigationBarHidden = true
        interactivePopGestureRecognizer?.isEnabled = false
    }
}
