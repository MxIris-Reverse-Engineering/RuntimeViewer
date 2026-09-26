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
open class BaseViewController<ViewModel: ViewModelProtocol>: NSLayerBackedViewController {
    public private(set) var viewModel: ViewModel?

    /// Frosted glass before macOS 26 and transparent from 26 on, unless a pane gives it a
    /// `backgroundColor` — the content panes use the editor's, to be covered while they load.
    let commonLoadingView = CommonLoadingView()

    public private(set) var contentView = NSView()

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

        // The whole view, not the safe area: a painted background has to cover the strip under
        // the toolbar as well. The spinner still centres in the safe area.
        if _shouldSetupCommonLoading {
            commonLoadingView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
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

/// A `BaseViewController` whose `contentView` is an `NSVisualEffectView` before macOS 26 and a plain
/// `NSView` from macOS 26 on.
///
/// From macOS 26 the split view wraps a sidebar or inspector item in an `NSGlassEffectView` whose
/// colour the window server composes live; no colour, material or nested glass matches it, so the
/// page stays transparent and sits on the glass directly. The opaque backdrop the sidebar's push /
/// pop needs is inserted under the sliding pages for the length of the transition by
/// `NavigationTransitionBackdropController`, not carried by the pages. Background:
/// `Documentations/ResolvedIssues/2026-09-18-sidebar-transition-backdrop-glass-replica.md`.
open class BaseEffectViewController<ViewModel: ViewModelProtocol>: BaseViewController<ViewModel> {
    private lazy var effectView: NSView = {
        if #available(macOS 26.0, *) {
            return NSView()
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
