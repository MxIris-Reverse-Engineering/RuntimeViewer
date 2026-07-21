import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerApplication

class SidebarRuntimeObjectViewController<ViewModel: SidebarRuntimeObjectViewModel>: UXKitViewController<ViewModel>, NSOutlineViewDelegate {
    var isReorderable: Bool {
        false
    }

    /// When `true`, the outline groups runtime objects into kind sections
    /// (`output.runtimeObjectSections`) and renders section group rows; when
    /// `false`, it shows the flat single-layer list (`output.runtimeObjects`).
    /// Sections and root-level reordering are mutually exclusive, so the
    /// reorderable bookmark variant keeps the flat list.
    var supportsSections: Bool {
        false
    }

    @ViewLoading
    private var tabView: NSTabView

    let imageNotLoadedView = ImageLoadableView()

    let imageLoadingView = ImageLoadingView()

    let imageLoadedView = ImageLoadedView()

    let imageLoadErrorView = ImageLoadableView()

    let imageUnknownView = ImageUnknownView()

    private let filterModeDidChange = BehaviorRelay<Void>(value: ())

    @Dependency(\.appDefaults)
    private var appDefaults

    var outlineView: StatefulOutlineView {
        imageLoadedView.outlineView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tabView = NSTabView()

        contentView.hierarchy {
            tabView
        }

        tabView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        tabView.do {
            $0.addTabViewItem(NSTabViewItem(view: imageNotLoadedView, loadState: .notLoaded))
            $0.addTabViewItem(NSTabViewItem(view: imageLoadingView, loadState: .loading))
            $0.addTabViewItem(NSTabViewItem(view: imageLoadedView, loadState: .loaded))
            $0.addTabViewItem(NSTabViewItem(view: imageLoadErrorView, loadState: .loadError(NSTabViewItem.PlaceholderLoadStateError.main)))
            $0.addTabViewItem(NSTabViewItem(view: imageUnknownView, loadState: .unknown))
            $0.tabViewType = .noTabsNoBorder
            $0.tabPosition = .none
            $0.tabViewBorderType = .none
        }

        imageLoadedView.filterModeButton.do {
            $0.onItem = appDefaults.filterMode
            $0.stateChanged = { [weak self] filterMode in
                guard let self else { return }
                appDefaults.filterMode = filterMode
                filterModeDidChange.accept()
            }
        }
    }

    override func setupBindings(for viewModel: ViewModel) {
        super.setupBindings(for: viewModel)

        // Mouse click and arrow-key navigation are explicit user intents — load
        // immediately. Type-select character input fires a selection event on every
        // keystroke, so debounce that path to skip the intermediate rows and only
        // load the landing one.
        let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126] // Left, Right, Down, Up
        let isExplicitSelection: (NSEvent?) -> Bool = { event in
            guard let event else { return true }
            switch event.type {
            case .leftMouseUp:
                return true
            case .keyDown:
                return arrowKeyCodes.contains(event.keyCode)
            default:
                return true
            }
        }
        let userSelection = imageLoadedView.outlineView.rx.proposedSelection()
            .compactMap { [weak outlineView = imageLoadedView.outlineView] proposed -> (SidebarRuntimeObjectCellViewModel, NSEvent?)? in
                guard let outlineView,
                      let row = proposed.indexes.first,
                      let cellViewModel = outlineView.item(atRow: row) as? SidebarRuntimeObjectCellViewModel
                else { return nil }
                return (cellViewModel, proposed.triggeringEvent)
            }
            .share(replay: 0, scope: .whileConnected)
        let runtimeObjectClicked: Signal<SidebarRuntimeObjectCellViewModel> = .merge(
            userSelection.filter { isExplicitSelection($0.1) }.map(\.0).asSignal(onErrorSignalWith: .empty()),
            userSelection.filter { !isExplicitSelection($0.1) }.map(\.0).debounce(.milliseconds(800), scheduler: MainScheduler.instance).asSignal(onErrorSignalWith: .empty()),
        )

        // Row context menu. Items are rebuilt from `clickedRow` on every
        // `menuNeedsUpdate` (synchronously — no Driver hop, the menu shows
        // right after the delegate call returns); an empty item list keeps
        // AppKit from popping an empty menu on whitespace right-clicks.
        // `menu.rx.items` + `itemSelected` instead of target/action because
        // a generic class cannot host `@objc` menu actions.
        let contextMenu = NSMenu()
        imageLoadedView.outlineView.menu = contextMenu
        let contextMenuEntries: Observable<[OpenInNewTabMenuEntry]> = contextMenu.rx.needsUpdate
            .asObservable()
            .map { [weak outlineView = imageLoadedView.outlineView] _ -> [OpenInNewTabMenuEntry] in
                guard let outlineView,
                      outlineView.clickedRow >= 0,
                      let cellViewModel = outlineView.item(atRow: outlineView.clickedRow) as? SidebarRuntimeObjectCellViewModel
                else { return [] }
                return [OpenInNewTabMenuEntry(cellViewModel: cellViewModel)]
            }
        contextMenu.rx.items(source: contextMenuEntries)({ _, _ in }).disposed(by: rx.disposeBag)

        let input = ViewModel.Input(
            runtimeObjectClicked: runtimeObjectClicked,
            runtimeObjectOpenedInNewTab: contextMenu.rx.itemSelected(OpenInNewTabMenuEntry.self)
                .map(\.item.cellViewModel)
                .asSignal(onErrorSignalWith: .empty()),
            loadImageClicked: Signal.of(
                imageNotLoadedView.loadImageButton.rx.click.asSignal(),
                imageLoadErrorView.loadImageButton.rx.click.asSignal(),
            ).merge(),
            searchString: .combineLatestFirstResult(
                imageLoadedView.filterSearchField.rx.stringValue.asDriver(),
                filterModeDidChange.asDriver(),
            ),
            isSearchCaseInsensitive: imageLoadedView.searchCaseInsensitiveButton.rx.state.asDriver().map { $0 == .on },
        )

        let output = viewModel.transform(input)

        let cellProvider = { (outlineView: NSOutlineView, _: NSTableColumn?, viewModel: SidebarRuntimeObjectCellViewModel) -> NSView? in
            outlineView.box.makeView(ofClass: RuntimeObjectCellView<SidebarRuntimeObjectCellViewModel>.self).then {
                $0.bind(to: viewModel)
            }
        }

        if supportsSections {
            let sectionsSource = output.runtimeObjectSections
                .asObservable()
                .map { $0.map { ArraySection(model: $0, elements: $0.objects) } }
            let sectionHeaderProvider = { (outlineView: NSOutlineView, _: NSTableColumn?, section: SidebarRuntimeObjectSection) -> NSView? in
                let headerView = outlineView.box.makeView(ofClass: SectionHeaderView.self)
                headerView.configure(title: section.title)
                return headerView
            }
            imageLoadedView.outlineView.rx.sections(source: sectionsSource)(sectionHeaderProvider, cellProvider).disposed(by: rx.disposeBag)
        } else {
            imageLoadedView.outlineView.rx.nodes(source: output.runtimeObjects.asObservable(), options: isReorderable ? [.reorderable] : [])(cellProvider).disposed(by: rx.disposeBag)
        }

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
            imageLoadedView.outlineView.reloadData()
        }
        .disposed(by: rx.disposeBag)

        output.didEndFiltering.emitOnNext { [weak self] in
            guard let self else { return }
            imageLoadedView.outlineView.endFiltering()
        }
        .disposed(by: rx.disposeBag)

        output.reloadRow.emitOnNext { [weak self] parentViewModel in
            guard let self else { return }
            // `outlineView.rx.nodes` uses DifferenceKit, which can not detect
            // mutation of a reference-typed cell viewModel (the same instance
            // lives in both source/target snapshots, so `isContentEqual` always
            // returns true). Drive child visibility off this explicit signal so
            // the outline view re-queries `numberOfChildrenOfItem` whenever a
            // specialized child is spliced into a parent. Expand the parent so
            // the freshly-inserted child is visible without an extra click.
            imageLoadedView.outlineView.reloadItem(parentViewModel, reloadChildren: true)
            imageLoadedView.outlineView.expandItem(parentViewModel)
        }
        .disposed(by: rx.disposeBag)

        output.loadState.driveOnNextMainActor { [weak self] loadState in
            guard let self else { return }
            tabView.selectTabViewItem(withIdentifier: loadState.tabViewItemIdentifier)
        }
        .disposed(by: rx.disposeBag)

        output.loadingProgress.driveOnNextMainActor { [weak self] progress in
            guard let self else { return }
            imageLoadingView.progressIndicator.doubleValue = progress
        }
        .disposed(by: rx.disposeBag)

        output.loadingDescription.drive(imageLoadingView.descriptionLabel.rx.stringValue)
            .disposed(by: rx.disposeBag)

        output.loadingItemCount.drive(imageLoadingView.countLabel.rx.stringValue)
            .disposed(by: rx.disposeBag)

        outlineView.rx.shouldSelectItem { _, item, _, _ in
            !(item is SidebarRuntimeObjectSection)
        }
        .disposed(by: rx.disposeBag)

        outlineView.rx.setDelegate(self).disposed(by: rx.disposeBag)

        outlineView.identifier = "com.JH.RuntimeViewer.\(Self.self).identifier.\(viewModel.documentState.runtimeEngine.source.description)"
        outlineView.autosaveName = "com.JH.RuntimeViewer.\(Self.self).autosaveName.\(viewModel.documentState.runtimeEngine.source.description)"

        imageLoadedView.filterScopeButton.rx.click.asSignal()
            .emitOnNextMainActor { [weak self, weak viewModel] in
                guard let self, let viewModel else { return }
                viewModel.router.trigger(
                    .scope(
                        sender: imageLoadedView.filterScopeButton,
                        relay: viewModel.$scope,
                        availableKinds: viewModel.availableKinds,
                        availableProperties: viewModel.availableProperties,
                    ),
                )
            }
            .disposed(by: rx.disposeBag)

        viewModel.$scope
            .asDriver()
            .map(\.isActive)
            .distinctUntilChanged()
            .driveOnNextMainActor { [weak self] isActive in
                guard let self else { return }
                imageLoadedView.filterScopeButton.contentTintColor = isActive ? .controlAccentColor : .labelColor
            }
            .disposed(by: rx.disposeBag)
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard let cellViewModel = item as? SidebarRuntimeObjectCellViewModel else { return nil }
        return cellViewModel.title.string
    }
}

/// Row context menu entry carrying the clicked cell for `menu.rx.items` /
/// `itemSelected`. File-scoped (not nested) because the enclosing view
/// controller is generic.
private struct OpenInNewTabMenuEntry: RxMenuItemRepresentable {
    let cellViewModel: SidebarRuntimeObjectCellViewModel

    var title: String { "Open in New Tab" }
}

extension SidebarRuntimeObjectViewController {
    /// Group-row cell for a kind section header (e.g. "Objective-C Class").
    /// Rendered as an `NSOutlineView` group item; the system applies the
    /// standard group-row styling, so this only supplies the title text.
    private final class SectionHeaderView: LayerBackedView {
        private let titleLabel = Label()

        override func setup() {
            super.setup()

            addSubview(titleLabel)

            titleLabel.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview()
                make.top.bottom.equalToSuperview().inset(2)
            }

            titleLabel.do {
                $0.font = .systemFont(ofSize: 11, weight: .semibold)
                $0.textColor = .secondaryLabelColor
                $0.alignment = .left
                $0.maximumNumberOfLines = 1
            }
        }

        func configure(title: String) {
            titleLabel.stringValue = title
        }
    }

    final class ImageUnknownView: XiblessView {}

    final class ImageLoadedView: XiblessView {
        let (scrollView, outlineView): (ScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()

        let emptyLabel = Label()

        let bottomSeparatorView = NSBox()

        let filterModeButton = ItemPopUpButton<FilterMode>()

        let filterScopeButton = NSButton()

        let filterSearchField = FilterSearchField()

        private lazy var filterStackView = HStackView(distribution: .fill, alignment: .fill, spacing: 6) {
            filterModeButton
            filterScopeButton
            filterSearchField
        }

        private(set) var searchCaseInsensitiveButton: NSButton!

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            searchCaseInsensitiveButton = filterSearchField.addFilterButton(
                systemSymbolName: "textformat",
                toolTip: "Case Insensitive",
            )

            hierarchy {
                scrollView
                emptyLabel
                bottomSeparatorView
                filterStackView
            }

            scrollView.snp.makeConstraints { make in
                make.top.left.right.equalToSuperview()
                make.bottom.equalTo(bottomSeparatorView.snp.top)
            }

            emptyLabel.snp.makeConstraints { make in
                make.centerX.equalToSuperview()
                make.centerY.equalTo(scrollView)
                make.top.left.greaterThanOrEqualTo(16).priority(.high)
                make.right.lessThanOrEqualTo(-16).priority(.high)
                make.bottom.lessThanOrEqualTo(bottomSeparatorView.snp.top).offset(-16).priority(.high)
            }

            bottomSeparatorView.snp.makeConstraints { make in
                make.left.right.equalToSuperview()
                make.height.equalTo(1)
//                make.bottom.equalTo(filterSearchField.snp.top).offset(-8)
                make.bottom.equalTo(filterStackView.snp.top).offset(-8)
            }

            searchCaseInsensitiveButton.snp.makeConstraints { make in
                make.top.bottom.equalToSuperview()
            }
//            filterModeButton.snp.makeConstraints { make in
//                make.left.equalToSuperview().inset(12)
//                make.centerY.equalTo(filterSearchField)
//            }
//
//            filterScopeButton.snp.makeConstraints { make in
//                make.left.equalTo(filterModeButton.snp.right).offset(6)
//                make.centerY.equalTo(filterSearchField)
//            }
//
//            filterSearchField.snp.makeConstraints { make in
//                make.left.equalTo(filterScopeButton.snp.right).offset(6)
//                make.right.equalToSuperview().inset(10)
//                make.bottom.equalToSuperview().inset(8)
//            }

            filterStackView.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview().inset(12)
                make.bottom.equalToSuperview().inset(8)
            }

            emptyLabel.do {
                $0.alignment = .center
                $0.maximumNumberOfLines = 0
                $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }

            scrollView.do {
                $0.autohidesScrollers = true
                $0.isHiddenVisualEffectView = true
            }

            bottomSeparatorView.do {
                $0.boxType = .separator
            }

            filterModeButton.do {
                $0.icon = .symbol(systemName: .line3HorizontalDecrease)
                $0.alternateIcon = SFSymbols(systemName: .line3HorizontalDecrease).hierarchicalColor(.controlAccentColor).nsuiImgae
                $0.setup()
            }

            filterScopeButton.do {
                $0.isBordered = false
                $0.imagePosition = .imageOnly
                $0.image = .symbol(systemName: .sliderHorizontal3)
                $0.toolTip = "Filter Scope"
            }

            filterSearchField.do {
                if #available(macOS 26.0, *) {
                    $0.controlSize = .extraLarge
                } else {
                    $0.controlSize = .large
                }
            }
        }
    }

    final class ImageLoadingView: XiblessView {
        let progressIndicator = NSProgressIndicator()
        let descriptionLabel = Label()
        let countLabel = Label()

        override init(frame frameRect: CGRect) {
            super.init(frame: frameRect)

            let contentStack = VStackView(alignment: .center, spacing: 8) {
                progressIndicator
                descriptionLabel
                countLabel
            }

            hierarchy {
                contentStack
            }

            contentStack.snp.makeConstraints { make in
                make.center.equalToSuperview()
            }

            progressIndicator.snp.makeConstraints { make in
                make.width.equalTo(260)
            }

            progressIndicator.do {
                $0.style = .bar
                $0.isIndeterminate = false
                $0.minValue = 0
                $0.maxValue = 1
                $0.doubleValue = 0
            }

            descriptionLabel.do {
                $0.textColor = .secondaryLabelColor
                $0.font = .systemFont(ofSize: 12)
                $0.alignment = .center
            }

            countLabel.do {
                $0.textColor = .tertiaryLabelColor
                $0.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                $0.alignment = .center
            }
        }
    }

    final class ImageLoadableView: XiblessView {
        let titleLabel = Label()

        let loadImageButton = PushButton()

        lazy var contentView = VStackView(alignment: .center, spacing: 10) {
            titleLabel
                .stackView
                .gravity(.center)
            loadImageButton
                .stackView
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
    fileprivate enum PlaceholderLoadStateError: Error {
        case main
    }

    fileprivate convenience init(view: NSView, loadState: RuntimeImageLoadState) {
        self.init(identifier: loadState.tabViewItemIdentifier)
        let vc = NSViewController()
        vc.view = view
        self.viewController = vc
    }
}


public extension SharedSequence {

    static func combineLatestFirstResult<
        FirstSharedSequence: SharedSequenceConvertibleType,
        SecondSharedSequence: SharedSequenceConvertibleType
    >(
        _ firstSharedSequence: FirstSharedSequence,
        _ secondSharedSequence: SecondSharedSequence
    ) -> SharedSequence<SharingStrategy, Element>
    where
        FirstSharedSequence.SharingStrategy == SharingStrategy,
        SecondSharedSequence.SharingStrategy == SharingStrategy,
        FirstSharedSequence.Element == Element
    {
        combineLatest(
            firstSharedSequence,
            secondSharedSequence,
            resultSelector: { firstElement, _ in firstElement }
        )
    }

    static func combineLatestSecondResult<
        FirstSharedSequence: SharedSequenceConvertibleType,
        SecondSharedSequence: SharedSequenceConvertibleType
    >(
        _ firstSharedSequence: FirstSharedSequence,
        _ secondSharedSequence: SecondSharedSequence
    ) -> SharedSequence<SharingStrategy, Element>
    where
        FirstSharedSequence.SharingStrategy == SharingStrategy,
        SecondSharedSequence.SharingStrategy == SharingStrategy,
        SecondSharedSequence.Element == Element
    {
        combineLatest(
            firstSharedSequence,
            secondSharedSequence,
            resultSelector: { _, secondElement in secondElement }
        )
    }
}
