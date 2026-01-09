import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerApplication

final class SidebarImageViewController: UXEffectViewController<SidebarImageViewModel> {
    private let tabView = NSTabView()

    private let imageNotLoadedView = ImageLoadableView()

    private let imageLoadingView = ImageLoadingView()

    private let imageLoadedView = ImageLoadedView()

    private let imageLoadErrorView = ImageLoadableView()

    private let imageUnknownView = ImageUnknownView()

    private let filterModeButton = ItemPopUpButton<FilterMode>()

    private let filterSearchField = FilterSearchField()

    private let bottomSeparatorView = NSBox()

    private var previousWindowSubtitle: String = ""

    private var previousWindowTitle: String = ""

    private let filterModeDidChange = PublishRelay<Void>()

    private let openQuicklyActionBar = DSFQuickActionBar()

    private let openQuicklyActivateRelay = PublishRelay<SidebarImageCellViewModel>()

    private let searchStringDidChangeForOpenQuickly = PublishRelay<String>()

    private var currentSearchTask: DSFQuickActionBar.SearchTask?

    @Dependency(\.appDefaults)
    private var appDefaults

    override func viewDidLoad() {
        super.viewDidLoad()

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
        }

        tabView.do {
            $0.addTabViewItem(NSTabViewItem(view: imageNotLoadedView, loadState: .notLoaded))
            $0.addTabViewItem(NSTabViewItem(view: imageLoadingView, loadState: .loading))
            $0.addTabViewItem(NSTabViewItem(view: imageLoadedView, loadState: .loaded))
            $0.addTabViewItem(NSTabViewItem(view: imageLoadErrorView, loadState: .loadError(Optional.none)))
            $0.addTabViewItem(NSTabViewItem(view: imageUnknownView, loadState: .unknown))
            $0.tabViewType = .noTabsNoBorder
            $0.tabPosition = .none
            $0.tabViewBorderType = .none
        }

        openQuicklyActionBar.do {
            $0.contentSource = self
        }
    }

    override func setupBindings(for viewModel: SidebarImageViewModel) {
        super.setupBindings(for: viewModel)

        let input = SidebarImageViewModel.Input(
            runtimeObjectClicked: imageLoadedView.outlineView.rx.modelSelected().asSignal(),
            runtimeObjectClickedForOpenQuickly: openQuicklyActivateRelay.asSignal(),
            loadImageClicked: Signal.of(
                imageNotLoadedView.loadImageButton.rx.click.asSignal(),
                imageLoadErrorView.loadImageButton.rx.click.asSignal()
            ).merge(),
            searchString: .combineLatest(filterSearchField.rx.stringValue.asSignal(), filterModeDidChange.asSignal().startWith(()), resultSelector: { a, b in a }),
            searchStringForOpenQuickly: searchStringDidChangeForOpenQuickly.asSignal()
        )

        let output = viewModel.transform(input)

        output.runtimeObjects.drive(imageLoadedView.outlineView.rx.nodes) { (outlineView: NSOutlineView, tableColumn: NSTableColumn?, viewModel: SidebarImageCellViewModel) -> NSView? in
            let cellView = outlineView.box.makeView(ofClass: SidebarImageCellView.self) { .init(forOpenQuickly: false) }
            cellView.bind(to: viewModel)
            return cellView
        }
        .disposed(by: rx.disposeBag)

        output.runtimeObjectsForOpenQuickly.driveOnNextMainActor { [weak self] viewModels in
            guard let self else { return }
            currentSearchTask?.complete(with: viewModels)
            currentSearchTask = nil
        }
        .disposed(by: rx.disposeBag)

        output.errorText.drive(imageLoadErrorView.titleLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.notLoadedText.drive(imageNotLoadedView.titleLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.emptyText.drive(imageLoadedView.emptyLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.isEmpty.not().drive(imageLoadedView.emptyLabel.rx.isHidden).disposed(by: rx.disposeBag)

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

        output.selectRuntimeObject.emitOnNextMainActor { [weak self] item in
            guard let self else { return }
            let outlineView = imageLoadedView.outlineView
            let row = outlineView.row(forItem: item)
            guard row >= 0, row < outlineView.numberOfRows else { return }
            outlineView.selectRowIndexes(.init(integer: row), byExtendingSelection: false)
            guard !outlineView.visibleRowIndexes.contains(row) else { return }
            outlineView.scrollRowToVisible(row, animated: false, scrollPosition: .centeredVertically)
        }
        .disposed(by: rx.disposeBag)

        output.windowInitialTitles.driveOnNext { [weak self] in
            guard let self, let window = view.window else { return }
            previousWindowTitle = window.title
            previousWindowSubtitle = window.subtitle
            window.title = $0.title
            window.subtitle = $0.subtitle
        }
        .disposed(by: rx.disposeBag)

        output.loadState.driveOnNextMainActor { [weak self] loadState in
            guard let self else { return }
            tabView.selectTabViewItem(withIdentifier: loadState.tabViewItemIdentifier)
        }
        .disposed(by: rx.disposeBag)

        imageLoadedView.outlineView.identifier = "com.JH.RuntimeViewer.\(ImageLoadedView.self).identifier.\(viewModel.appServices.runtimeEngine.source.description)"
        imageLoadedView.outlineView.autosaveName = "com.JH.RuntimeViewer.\(ImageLoadedView.self).autosaveName.\(viewModel.appServices.runtimeEngine.source.description)"
    }

    @IBAction func openQuickly(_ sender: Any?) {
        openQuicklyActionBar.cancel()
        openQuicklyActionBar.present(
            parentWindow: view.window,
            placeholderText: "Open Quickly",
            searchImage: nil,
            initialSearchText: nil,
            showKeyboardShortcuts: false,
            canBecomeMainWindow: false
        ) {}
    }
}

extension SidebarImageViewController: DSFQuickActionBarContentSource {
    func quickActionBar(_ quickActionBar: DSFQuickActionBar, viewForItem item: AnyHashable, searchTerm: String) -> NSView? {
        guard let viewModel = item as? SidebarImageCellViewModel else { return nil }
        let cellView = SidebarImageCellView(forOpenQuickly: true)
        cellView.bind(to: viewModel)
        return cellView
    }

    func quickActionBar(_ quickActionBar: DSFQuickActionBar, itemsForSearchTermTask task: DSFQuickActionBar.SearchTask) {
        currentSearchTask = task
        searchStringDidChangeForOpenQuickly.accept(task.searchTerm)
    }

    func quickActionBar(_ quickActionBar: DSFQuickActionBar, didActivateItem item: AnyHashable) {
        guard let viewModel = item as? SidebarImageCellViewModel else { return }
        openQuicklyActivateRelay.accept(viewModel)
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

extension SidebarImageViewController {
    private final class ImageUnknownView: XiblessView {}

    private final class ImageLoadedView: XiblessView {
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
                make.top.left.greaterThanOrEqualTo(16)
                make.bottom.right.lessThanOrEqualTo(16)
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
            }
        }
    }

    private final class ImageLoadingView: XiblessView {
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

    private final class ImageLoadableView: XiblessView {
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

extension NSTabViewItem {
    fileprivate convenience init(view: NSView, loadState: RuntimeImageLoadState) {
        self.init(identifier: loadState.tabViewItemIdentifier)
        let vc = NSViewController()
        vc.view = view
        self.viewController = vc
    }
}

extension NSPopUpButton {
    var popUpButtonCell: NSPopUpButtonCell? {
        cell as? NSPopUpButtonCell
    }
}

extension DSFQuickActionBar: Then {}

extension NSTableView {
    /// 定义滚动位置的选项集合
    struct ScrollPosition: OptionSet {
        let rawValue: UInt

        init(rawValue: UInt) {
            self.rawValue = rawValue
        }

        static let none = ScrollPosition([])

        // --- 垂直方向 (用于行) ---
        /// 将行滚动到可视区域顶部
        static let top = ScrollPosition(rawValue: 1 << 0)
        /// 将行滚动到可视区域垂直居中
        static let centeredVertically = ScrollPosition(rawValue: 1 << 1)
        /// 将行滚动到可视区域底部
        static let bottom = ScrollPosition(rawValue: 1 << 2)
        /// 滚动到最近的边缘 (上或下)
        static let nearestHorizontalEdge = ScrollPosition(rawValue: 1 << 9)

        // --- 水平方向 (用于列) ---
        /// 将列滚动到可视区域左侧
        static let left = ScrollPosition(rawValue: 1 << 3)
        /// 将列滚动到可视区域水平居中
        static let centeredHorizontally = ScrollPosition(rawValue: 1 << 4)
        /// 将列滚动到可视区域右侧
        static let right = ScrollPosition(rawValue: 1 << 5)
        // (注: Leading/Trailing 在这里简化映射为 Left/Right，可视需求扩展 RTL 支持)
        static let leadingEdge = ScrollPosition(rawValue: 1 << 6)
        static let trailingEdge = ScrollPosition(rawValue: 1 << 7)
        static let nearestVerticalEdge = ScrollPosition(rawValue: 1 << 8)
    }

    // MARK: - 2. 增强版 Scroll Row

    /// 滚动指定行到特定位置，支持动画
    /// - Parameters:
    ///   - row: 目标行索引
    ///   - animated: 是否使用动画 (默认为 true)
    ///   - scrollPosition: 滚动停靠位置 (.top, .centeredVertically, .bottom)
    func scrollRowToVisible(_ row: Int, animated: Bool = true, scrollPosition: ScrollPosition) {
        // 越界检查
        guard row >= 0, row < numberOfRows else { return }

        // 如果是 .none，回退到系统默认行为 (非动画)
        if scrollPosition == .none {
            scrollRowToVisible(row)
            return
        }

        // 1. 获取几何信息
        let rowRect = rect(ofRow: row)
        let visibleRect = self.visibleRect
        guard let clipView = enclosingScrollView?.contentView else { return }

        // 2. 计算目标 Y 坐标
        var finalY = visibleRect.origin.y

        // 优先检查垂直方向的位掩码
        if scrollPosition.contains(.top) || scrollPosition.contains(.leadingEdge) {
            finalY = rowRect.origin.y
        } else if scrollPosition.contains(.centeredVertically) {
            finalY = rowRect.midY - (visibleRect.height / 2.0)
        } else if scrollPosition.contains(.bottom) || scrollPosition.contains(.trailingEdge) {
            finalY = rowRect.maxY - visibleRect.height
        } else if scrollPosition.contains(.nearestHorizontalEdge) {
            // 计算离上边近还是离下边近
            let distToTop = abs(visibleRect.minY - rowRect.minY)
            let distToBottom = abs(visibleRect.maxY - rowRect.maxY)
            if distToTop < distToBottom {
                finalY = rowRect.origin.y
            } else {
                finalY = rowRect.maxY - visibleRect.height
            }
        }

        // 3. 边界修正 (防止滚出画布范围)
        // 确保 newY 不会小于 0，也不会大于 (总高度 - 可视高度)
        let maxScrollY = clipView.documentRect.height - visibleRect.height
        finalY = max(0, min(finalY, maxScrollY))

        // 4. 执行滚动
        let finalPoint = NSPoint(x: visibleRect.origin.x, y: finalY)
        scrollToPoint(finalPoint, animated: animated)
    }

    // MARK: - 3. 增强版 Scroll Column

    /// 滚动指定列到特定位置，支持动画
    func scrollColumnToVisible(_ column: Int, animated: Bool = true, scrollPosition: ScrollPosition) {
        guard column >= 0, column < numberOfColumns else { return }

        if scrollPosition == .none {
            scrollColumnToVisible(column)
            return
        }

        let colRect = rect(ofColumn: column)
        let visibleRect = self.visibleRect
        guard let clipView = enclosingScrollView?.contentView else { return }

        var finalX = visibleRect.origin.x

        if scrollPosition.contains(.left) || scrollPosition.contains(.leadingEdge) {
            finalX = colRect.origin.x
        } else if scrollPosition.contains(.centeredHorizontally) {
            finalX = colRect.midX - (visibleRect.width / 2.0)
        } else if scrollPosition.contains(.right) || scrollPosition.contains(.trailingEdge) {
            finalX = colRect.maxX - visibleRect.width
        } else if scrollPosition.contains(.nearestVerticalEdge) {
            let distToLeft = abs(visibleRect.minX - colRect.minX)
            let distToRight = abs(visibleRect.maxX - colRect.maxX)
            if distToLeft < distToRight {
                finalX = colRect.origin.x
            } else {
                finalX = colRect.maxX - visibleRect.width
            }
        }

        let maxScrollX = clipView.documentRect.width - visibleRect.width
        finalX = max(0, min(finalX, maxScrollX))

        let finalPoint = NSPoint(x: finalX, y: visibleRect.origin.y)
        scrollToPoint(finalPoint, animated: animated)
    }

    // MARK: - Private Helper

    /// 统一处理动画与非动画滚动的私有辅助方法
    private func scrollToPoint(_ point: NSPoint, animated: Bool) {
        guard let scrollView = enclosingScrollView else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25 // 系统默认动画时长通常为 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                // 使用 animator 代理进行平滑滚动
                scrollView.contentView.animator().setBoundsOrigin(point)

                // 注意: 对于 NSScrollView，通常不需要手动调用 reflectScrolledClipView，
                // 但如果出现滚动条不更新的情况，可以在 completion handler 中调用。
            } completionHandler: {
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else {
            scrollView.contentView.scroll(to: point)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}
