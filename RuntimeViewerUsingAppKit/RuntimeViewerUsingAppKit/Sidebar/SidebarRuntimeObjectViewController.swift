import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerApplication

class SidebarRuntimeObjectViewController<ViewModel: SidebarRuntimeObjectViewModel>: UXKitViewController<ViewModel> {
    
    var isReorderable: Bool { false }
    
    @ViewLoading
    private var tabView: NSTabView

    let imageNotLoadedView = ImageLoadableView()

    let imageLoadingView = ImageLoadingView()

    let imageLoadedView = ImageLoadedView()

    let imageLoadErrorView = ImageLoadableView()

    let imageUnknownView = ImageUnknownView()

    private let filterModeButton = ItemPopUpButton<FilterMode>()

    private let filterSearchField = FilterSearchField()

    private let bottomSeparatorView = NSBox()

    private let filterModeDidChange = PublishRelay<Void>()

    private var searchCaseInsensitiveButton: NSButton?

    @Dependency(\.appDefaults)
    private var appDefaults

    var outlineView: StatefulOutlineView { imageLoadedView.outlineView }

    override func viewDidLoad() {
        super.viewDidLoad()

        tabView = NSTabView()
        tabView.addTabViewItem(NSTabViewItem(view: imageNotLoadedView, loadState: .notLoaded))
        tabView.addTabViewItem(NSTabViewItem(view: imageLoadingView, loadState: .loading))
        tabView.addTabViewItem(NSTabViewItem(view: imageLoadedView, loadState: .loaded))
        tabView.addTabViewItem(NSTabViewItem(view: imageLoadErrorView, loadState: .loadError(Optional.none)))
        tabView.addTabViewItem(NSTabViewItem(view: imageUnknownView, loadState: .unknown))
        tabView.tabViewType = .noTabsNoBorder
        tabView.tabPosition = .none
        tabView.tabViewBorderType = .none

        contentView.hierarchy {
            tabView
            bottomSeparatorView
            filterModeButton
            filterSearchField
        }

        tabView.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
            make.bottom.equalTo(bottomSeparatorView.snp.top)
        }

        bottomSeparatorView.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
            make.bottom.equalTo(filterSearchField.snp.top).offset(-8)
            make.height.equalTo(1)
        }

        filterModeButton.snp.makeConstraints { make in
            make.left.equalToSuperview().inset(12)
            make.centerY.equalTo(filterSearchField)
        }

        filterSearchField.snp.makeConstraints { make in
            make.left.equalTo(filterModeButton.snp.right).offset(8)
            make.right.equalToSuperview().inset(10)
            make.bottom.equalToSuperview().inset(8)
        }

        bottomSeparatorView.do {
            $0.boxType = .separator
        }

        filterModeButton.do {
            $0.icon = .symbol(systemName: .line3HorizontalDecrease)
            $0.setup()
            $0.onItem = appDefaults.filterMode
            $0.stateChanged = { [weak self] filterMode in
                guard let self else { return }
                appDefaults.filterMode = filterMode
                filterModeDidChange.accept()
            }
        }

        filterSearchField.do {
            if #available(macOS 26.0, *) {
                $0.controlSize = .extraLarge
            } else {
                $0.controlSize = .large
            }

            $0.addFilterButton(systemSymbolName: "textformat", toolTip: "Case Insensitive").do { searchCaseInsensitiveButton = $0 }
        }
    }

    override func setupBindings(for viewModel: ViewModel) {
        super.setupBindings(for: viewModel)

        let input = ViewModel.Input(
            runtimeObjectClicked: imageLoadedView.outlineView.rx.modelSelected().asSignal(),
            loadImageClicked: Signal.of(
                imageNotLoadedView.loadImageButton.rx.click.asSignal(),
                imageLoadErrorView.loadImageButton.rx.click.asSignal()
            ).merge(),
            searchString: .combineLatest(filterSearchField.rx.stringValue.asSignal(), filterModeDidChange.asSignal().startWith(()), resultSelector: { a, b in a }),
            isSearchCaseInsensitive: searchCaseInsensitiveButton?.rx.state.asDriver().map { $0 == .on }
        )

        let output = viewModel.transform(input)

        output.runtimeObjects.drive(isReorderable ? imageLoadedView.outlineView.rx.reorderableNodes : imageLoadedView.outlineView.rx.nodes) { (outlineView: NSOutlineView, tableColumn: NSTableColumn?, viewModel: SidebarRuntimeObjectCellViewModel) -> NSView? in
            let cellView = outlineView.box.makeView(ofClass: SidebarRuntimeObjectCellView.self) { .init(forOpenQuickly: false) }
            cellView.bind(to: viewModel)
            return cellView
        }
        .disposed(by: rx.disposeBag)

        output.errorText.drive(imageLoadErrorView.titleLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.notLoadedText.drive(imageNotLoadedView.titleLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.emptyText.drive(imageLoadedView.emptyLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.isEmpty.not().drive(imageLoadedView.emptyLabel.rx.isHidden).disposed(by: rx.disposeBag)
        
        output.isEmpty.drive(imageLoadedView.scrollView.rx.isHidden).disposed(by: rx.disposeBag)

        output.didBeginFiltering.emitOnNext { [weak self] in
            guard let self else { return }
            imageLoadedView.outlineView.beginFiltering()
        }
        .disposed(by: rx.disposeBag)

        output.didChangeFiltering.emitOnNext { [weak self] in
            guard let self else { return }
            imageLoadedView.outlineView.expandItem(nil, expandChildren: true)
        }
        .disposed(by: rx.disposeBag)

        output.didEndFiltering.emitOnNext { [weak self] in
            guard let self else { return }
            imageLoadedView.outlineView.endFiltering()
        }
        .disposed(by: rx.disposeBag)

        output.windowInitialTitles.driveOnNext { [weak self] in
            guard let self else { return }
            self.viewModel?.documentState.currentSubtitle = $0.subtitle
        }
        .disposed(by: rx.disposeBag)

        output.loadState.driveOnNextMainActor { [weak self] loadState in
            guard let self else { return }
            tabView.selectTabViewItem(withIdentifier: loadState.tabViewItemIdentifier)
        }
        .disposed(by: rx.disposeBag)
        
        outlineView.identifier = "com.JH.RuntimeViewer.\(Self.self).identifier.\(viewModel.documentState.runtimeEngine.source.description)"
        outlineView.autosaveName = "com.JH.RuntimeViewer.\(Self.self).autosaveName.\(viewModel.documentState.runtimeEngine.source.description)"
    }
}

extension SidebarRuntimeObjectViewController {
    final class ImageUnknownView: XiblessView {}

    final class ImageLoadedView: XiblessView {
        let (scrollView, outlineView): (ScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableOutlineView()

        let emptyLabel = Label()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            hierarchy {
                scrollView
                emptyLabel
            }

            scrollView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }

            emptyLabel.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.top.left.greaterThanOrEqualTo(16).priority(.high)
                make.bottom.right.lessThanOrEqualTo(-16).priority(.high)
            }

            emptyLabel.do {
                $0.alignment = .center
                $0.maximumNumberOfLines = 0
                $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }

            scrollView.do {
                $0.isHiddenVisualEffectView = true
            }

            outlineView.do {
                $0.headerView = nil
                $0.style = .inset
                $0.addTableColumn(.init(identifier: "Default Column"))
                $0.autoresizesOutlineColumn = false
            }
        }
    }

    final class ImageLoadingView: XiblessView {
        let loadingIndicator: MaterialLoadingIndicator = .init(radius: 25, color: .controlAccentColor)

        override init(frame frameRect: CGRect) {
            super.init(frame: frameRect)

            hierarchy {
                loadingIndicator
            }

            loadingIndicator.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.size.equalTo(50)
            }

            loadingIndicator.startAnimating()
            loadingIndicator.lineWidth = 5
        }
    }

    final class ImageLoadableView: XiblessView {
        let titleLabel = Label()

        let loadImageButton = PushButton()

        lazy var contentView = VStackView(alignment: .vStackCenter, spacing: 10) {
            titleLabel
                .gravity(.center)
            loadImageButton
                .gravity(.center)
        }

        override init(frame frameRect: CGRect) {
            super.init(frame: frameRect)

            hierarchy {
                contentView
            }

            contentView.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.width.equalTo(200)
            }

            titleLabel.do {
                $0.isSelectable = true
                $0.alignment = .center
            }

            loadImageButton.do {
                $0.title = "Load now"
            }
        }
    }
}

extension Void?: @retroactive Error {}

extension RuntimeImageLoadState {
    fileprivate var tabViewItemIdentifier: String {
        switch self {
        case .notLoaded:
            return "notLoaded"
        case .loading:
            return "loading"
        case .loaded:
            return "loaded"
        case .loadError:
            return "loadError"
        case .unknown:
            return "unknown"
        }
    }
}

extension NSTabViewItem {
    fileprivate convenience init(view: NSView, loadState: RuntimeImageLoadState) {
        self.init(identifier: loadState.tabViewItemIdentifier)
        let vc = NSViewController()
        vc.view = view
        self.viewController = vc
    }
}

extension NSTableView {
    
}
