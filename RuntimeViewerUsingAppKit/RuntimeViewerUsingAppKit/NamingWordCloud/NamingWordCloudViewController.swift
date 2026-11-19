import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import SnapKit

/// The naming word cloud window's content, laid out as a native window: the
/// measure control, the member groups and the ⚙︎ and Export menus are the
/// window toolbar's items (this controller is the toolbar's delegate); the
/// cloud, on a canvas far larger than the window, fills the left, with its
/// status line and legend at the bottom left and the canvas controls at the
/// bottom right; an inspector column on the right holds the ranking of every
/// word above the names holding the selected one (proposal `naming-word-cloud`).
final class NamingWordCloudViewController: BaseViewController<NamingWordCloudViewModel>, NSToolbarDelegate {
    // MARK: - Relays

    /// Clicks on words of the cloud, which is drawn rather than built of controls.
    private let wordClickedRelay = PublishRelay<String?>()

    // MARK: - Toolbar

    private let measureControl = NSSegmentedControl(
        labels: NamingWordMeasure.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    private let memberGroupPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false).then {
        $0.addItems(withTitles: ["All Members"] + NamingMemberGroup.allCases.map(\.title))
    }

    private let removesPrefixesItem = NSMenuItem(title: "Remove Prefixes", action: nil, keyEquivalent: "")

    private let ignoresCommonWordsItem = NSMenuItem(title: "Ignore Common Words", action: nil, keyEquivalent: "")

    private let mergesCompoundWordsItem = NSMenuItem(title: "Merge Compound Words", action: nil, keyEquivalent: "")

    private let wordLimitItems: [NSMenuItem] = NamingWordCloudPreferences.wordLimitChoices.map { wordLimit in
        NSMenuItem(title: wordLimit.map { "\($0.formatted()) Words" } ?? "All Words", action: nil, keyEquivalent: "")
    }

    private let compoundWordsItem = NSMenuItem(title: "Compound Words…", action: nil, keyEquivalent: "")

    private let exportItems: [NSMenuItem] = NamingWordCloudExportFormat.allCases.map {
        NSMenuItem(title: $0.menuTitle, action: nil, keyEquivalent: "")
    }

    private lazy var measureToolbarItem = NSToolbarItem(itemIdentifier: .namingWordCloudMeasure).then {
        $0.view = measureControl
        $0.label = "Measure"
        $0.paletteLabel = "Measure"
        $0.toolTip = "What to count"
        $0.visibilityPriority = .high
    }

    private lazy var memberGroupToolbarItem = NSToolbarItem(itemIdentifier: .namingWordCloudMemberGroup).then {
        $0.view = memberGroupPopUpButton
        $0.label = "Members"
        $0.paletteLabel = "Members"
        $0.toolTip = "Which members to count"
    }

    private lazy var optionsToolbarItem = NSMenuToolbarItem(itemIdentifier: .namingWordCloudOptions).then { item in
        item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Options")
        item.label = "Options"
        item.paletteLabel = "Options"
        item.toolTip = "Options"
        item.showsIndicator = true
        item.menu = NSMenu().then { menu in
            menu.autoenablesItems = false
            menu.addItem(removesPrefixesItem)
            menu.addItem(ignoresCommonWordsItem)
            menu.addItem(mergesCompoundWordsItem)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Words in the Cloud"))
            wordLimitItems.forEach(menu.addItem)
            menu.addItem(.separator())
            menu.addItem(compoundWordsItem)
        }
    }

    private lazy var exportToolbarItem = NSMenuToolbarItem(itemIdentifier: .namingWordCloudExport).then { item in
        item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
        item.label = "Export"
        item.paletteLabel = "Export"
        item.toolTip = "Export"
        item.showsIndicator = true
        item.menu = NSMenu().then { menu in
            // The items are enabled by hand, while the cloud is ready.
            menu.autoenablesItems = false
            exportItems.forEach(menu.addItem)
        }
    }

    /// Lines the toolbar up with the divider before the inspector column.
    private lazy var inspectorSeparatorToolbarItem = NSTrackingSeparatorToolbarItem(
        identifier: .namingWordCloudInspectorSeparator,
        splitView: mainSplitView,
        dividerIndex: 0
    )

    // MARK: - Cloud

    private let wordCloudView = WordCloudView(frame: .zero)

    private let cloudScrollView = ScrollView().then {
        $0.contentView = CenteringClipView()
        $0.hasHorizontalScroller = true
        $0.hasVerticalScroller = true
        $0.autohidesScrollers = true
        $0.allowsMagnification = true
        $0.minMagnification = 0.1
        $0.maxMagnification = 4
        $0.drawsBackground = true
    }

    /// The status line and the legend, floating at the bottom left so that
    /// words scrolling under them stay legible.
    private let statusPlatterView = FloatingPlatterView(cornerRadius: 8)

    private let statusLabel = Label().then {
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .secondaryLabelColor
    }

    /// Filled with the legend's entries whenever the cloud's categories change.
    private let legendStackView = HStackView(spacing: 10) {}

    private let canvasControlsView = CanvasControlsView(frame: .zero)

    /// What shows instead of the cloud while it loads, or when it cannot be counted.
    private let progressIndicator = NSProgressIndicator().then {
        $0.style = .bar
        $0.controlSize = .small
        $0.isIndeterminate = true
    }

    private let messageLabel = Label().then {
        $0.alignment = .center
        $0.textColor = .secondaryLabelColor
        $0.maximumNumberOfLines = 0
        $0.lineBreakMode = .byWordWrapping
    }

    private let retryButton = PushButton().then {
        $0.title = "Retry"
    }

    private lazy var stateStackView = VStackView(alignment: .center, spacing: 12) {
        progressIndicator
        messageLabel
        retryButton
    }

    // MARK: - Inspector Column

    private let wordsTitleLabel = Label("Words").then {
        $0.font = .systemFont(ofSize: 13, weight: .semibold)
    }

    private let wordCountLabel = Label().then {
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .secondaryLabelColor
        $0.alignment = .right
    }

    private let (rankingScrollView, rankingTableView): (ScrollView, NSTableView) = NSTableView.scrollableTableView()

    private let rankingWordColumn = NSTableColumn(identifier: .namingWordCloudWord).then {
        $0.title = "Word"
        $0.minWidth = 80
    }

    private let rankingCountColumn = NSTableColumn(identifier: .namingWordCloudCount).then {
        $0.title = "Count"
        $0.width = 64
        $0.minWidth = 48
        $0.headerCell.alignment = .right
    }

    private let usedByTitleLabel = Label("Used By").then {
        $0.font = .systemFont(ofSize: 13, weight: .semibold)
    }

    private let usageTitleLabel = Label().then {
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .secondaryLabelColor
        $0.lineBreakMode = .byTruncatingTail
    }

    private let (usageScrollView, usageTableView): (ScrollView, NSTableView) = NSTableView.scrollableTableView()

    private let usageNameColumn = NSTableColumn(identifier: .namingWordCloudName).then {
        $0.title = "Name"
        $0.minWidth = 100
    }

    private let usageDetailColumn = NSTableColumn(identifier: .namingWordCloudDetail).then {
        $0.title = "Kind"
        $0.width = 96
        $0.minWidth = 60
    }

    private let mainSplitView = NSSplitView().then {
        $0.isVertical = true
        $0.dividerStyle = .thin
    }

    private let inspectorSplitView = NSSplitView().then {
        $0.isVertical = false
        $0.dividerStyle = .thin
    }

    // MARK: - State

    private static let inspectorInitialWidth: CGFloat = 320

    /// The space kept around the words when they are fitted into the window.
    private static let fitMargin: CGFloat = 24

    /// What a zoom button multiplies or divides the magnification by.
    private static let zoomStep: CGFloat = 1.25

    private var displayedPreferences = NamingWordCloudPreferences()

    private var displayedCloudWords: [NamingWordCloudWord] = []

    private var displayedWordCount = 0

    private var displayedSelectedWordKey: String?

    /// Set when words are laid out; the next layout pass with a visible area
    /// fits them into it.
    private var needsFitToVisibleArea = false

    private var layoutTask: Task<Void, Never>?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        cloudScrollView.documentView = wordCloudView
        let cloudContainerView = NSView()
        cloudContainerView.hierarchy {
            cloudScrollView
            statusPlatterView
            canvasControlsView
            stateStackView
        }
        statusPlatterView.contentView = HStackView(spacing: 12) {
            statusLabel
            legendStackView
        }
        .then { stack in
            stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        }

        let wordsSectionView = NSView()
        wordsSectionView.hierarchy {
            wordsTitleLabel
            wordCountLabel
            rankingScrollView
        }

        let usedBySectionView = NSView()
        usedBySectionView.hierarchy {
            usedByTitleLabel
            usageTitleLabel
            usageScrollView
        }

        inspectorSplitView.addArrangedSubview(wordsSectionView)
        inspectorSplitView.addArrangedSubview(usedBySectionView)
        mainSplitView.addArrangedSubview(cloudContainerView)
        mainSplitView.addArrangedSubview(inspectorSplitView)

        containerView.hierarchy {
            mainSplitView
        }

        mainSplitView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        cloudScrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        statusPlatterView.snp.makeConstraints { make in
            make.leading.bottom.equalToSuperview().inset(10)
            make.trailing.lessThanOrEqualTo(canvasControlsView.snp.leading).offset(-10)
        }
        canvasControlsView.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(10)
        }
        stateStackView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.lessThanOrEqualTo(360)
        }
        progressIndicator.snp.makeConstraints { make in
            make.width.equalTo(200)
        }
        wordsTitleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(10)
            make.leading.equalToSuperview().inset(12)
        }
        wordCountLabel.snp.makeConstraints { make in
            make.firstBaseline.equalTo(wordsTitleLabel)
            make.leading.greaterThanOrEqualTo(wordsTitleLabel.snp.trailing).offset(8)
            make.trailing.equalToSuperview().inset(12)
        }
        rankingScrollView.snp.makeConstraints { make in
            make.top.equalTo(wordsTitleLabel.snp.bottom).offset(6)
            make.leading.trailing.bottom.equalToSuperview()
        }
        usedByTitleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(10)
            make.leading.equalToSuperview().inset(12)
            make.trailing.lessThanOrEqualToSuperview().inset(12)
        }
        usageTitleLabel.snp.makeConstraints { make in
            make.top.equalTo(usedByTitleLabel.snp.bottom).offset(2)
            make.leading.trailing.equalToSuperview().inset(12)
        }
        usageScrollView.snp.makeConstraints { make in
            make.top.equalTo(usageTitleLabel.snp.bottom).offset(6)
            make.leading.trailing.bottom.equalToSuperview()
        }
        cloudContainerView.snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(360)
        }
        inspectorSplitView.snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(260)
        }
        wordsSectionView.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(120)
        }
        usedBySectionView.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(120)
        }

        setupTable(rankingTableView, scrollView: rankingScrollView, columns: [rankingWordColumn, rankingCountColumn])
        setupTable(usageTableView, scrollView: usageScrollView, columns: [usageNameColumn, usageDetailColumn])

        // The cloud's divider position is the window's own; the inspector's halves start equal.
        mainSplitView.box.restoreDividerPositions(autosaveName: "com.JH.RuntimeViewer.NamingWordCloud.main", initialPositions: [.distanceFromEnd(Self.inspectorInitialWidth)])
        inspectorSplitView.box.restoreDividerPositions(autosaveName: "com.JH.RuntimeViewer.NamingWordCloud.inspector", initialPositions: [.fractionOfLength(0.5)])

        canvasControlsView.magnificationRange = cloudScrollView.minMagnification ... cloudScrollView.maxMagnification
        cloudScrollView.contentView.postsBoundsChangedNotifications = true

        wordCloudView.wordClickHandler = { [weak self] identifier in
            guard let self else { return }
            wordClickedRelay.accept(identifier)
        }
        wordCloudView.layoutCompletionHandler = { [weak self] in
            guard let self else { return }
            updateStatusLine()
            needsFitToVisibleArea = true
            view.needsLayout = true
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitToVisibleAreaIfNeeded()
    }

    private func setupTable(_ tableView: NSTableView, scrollView: NSScrollView, columns: [NSTableColumn]) {
        tableView.do {
            $0.headerView = NSTableHeaderView()
            $0.style = .inset
            $0.allowsMultipleSelection = false
            $0.allowsColumnReordering = false
            $0.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            columns.forEach($0.addTableColumn)
        }
        scrollView.do {
            $0.drawsBackground = false
            $0.autohidesScrollers = true
            $0.borderType = .noBorder
        }
    }

    // MARK: - Toolbar Delegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .namingWordCloudMeasure,
            .namingWordCloudMemberGroup,
            .flexibleSpace,
            .namingWordCloudOptions,
            .namingWordCloudExport,
            .namingWordCloudInspectorSeparator,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .namingWordCloudMeasure: measureToolbarItem
        case .namingWordCloudMemberGroup: memberGroupToolbarItem
        case .namingWordCloudOptions: optionsToolbarItem
        case .namingWordCloudExport: exportToolbarItem
        case .namingWordCloudInspectorSeparator: inspectorSeparatorToolbarItem
        default: nil
        }
    }

    // MARK: - Canvas

    /// The PNG of the whole canvas; see `WordCloudView.pngDataOfWholeCanvas`.
    func wordCloudPNGData() -> Data? {
        wordCloudView.pngDataOfWholeCanvas()
    }

    /// Fits the words once they are laid out and the scroll view has a size,
    /// after the layout pass that gave it one: the clip view takes its new
    /// frame only when the scroll view lays itself out, later in that pass.
    private func fitToVisibleAreaIfNeeded() {
        guard needsFitToVisibleArea, view.window != nil, !cloudScrollView.isHidden else { return }
        let visibleSize = cloudScrollView.frame.size
        guard visibleSize.width > 0, visibleSize.height > 0, wordCloudView.wordsBoundingRect != nil else { return }
        needsFitToVisibleArea = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            zoomToFit(animated: false)
        }
    }

    /// Fits every word, with a margin, into the visible area and centres it,
    /// never past actual size.
    private func zoomToFit(animated: Bool) {
        guard let wordsRect = wordCloudView.wordsBoundingRect else { return }
        let fittedRect = wordsRect.insetBy(dx: -Self.fitMargin, dy: -Self.fitMargin)
        let visibleSize = cloudScrollView.contentView.frame.size
        guard fittedRect.width > 0, fittedRect.height > 0, visibleSize.width > 0, visibleSize.height > 0 else { return }
        let fittingMagnification = min(1, visibleSize.width / fittedRect.width, visibleSize.height / fittedRect.height)
        setMagnification(fittingMagnification, centeredAt: NSPoint(x: fittedRect.midX, y: fittedRect.midY), animated: animated)
    }

    /// Zooms by `factor` about the centre of the visible area.
    private func zoom(by factor: CGFloat) {
        let visibleRect = cloudScrollView.contentView.bounds
        setMagnification(cloudScrollView.magnification * factor, centeredAt: NSPoint(x: visibleRect.midX, y: visibleRect.midY), animated: true)
    }

    private func setMagnification(_ magnification: CGFloat, centeredAt point: NSPoint, animated: Bool) {
        let clampedMagnification = min(max(magnification, cloudScrollView.minMagnification), cloudScrollView.maxMagnification)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                cloudScrollView.animator().setMagnification(clampedMagnification, centeredAt: point)
            } completionHandler: { [weak self] in
                guard let self else { return }
                updateMagnificationDisplay()
            }
        } else {
            cloudScrollView.setMagnification(clampedMagnification, centeredAt: point)
            updateMagnificationDisplay()
        }
    }

    private func updateMagnificationDisplay() {
        canvasControlsView.magnification = cloudScrollView.magnification
    }

    private func scroll(toCenterOf rect: CGRect, animated: Bool) {
        let clipView = cloudScrollView.contentView
        let visibleSize = clipView.bounds.size
        let origin = NSPoint(x: rect.midX - visibleSize.width / 2, y: rect.midY - visibleSize.height / 2)
        let constrainedOrigin = clipView.constrainBoundsRect(NSRect(origin: origin, size: visibleSize)).origin
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                clipView.animator().setBoundsOrigin(constrainedOrigin)
            }
        } else {
            clipView.setBoundsOrigin(constrainedOrigin)
        }
        cloudScrollView.reflectScrolledClipView(clipView)
    }

    private func updateStatusLine() {
        let placedWordCount = wordCloudView.placedWordCount
        statusLabel.stringValue = "Showing \(placedWordCount.formatted()) of \(displayedWordCount.formatted()) words"
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: NamingWordCloudViewModel) {
        super.setupBindings(for: viewModel)

        wordCloudView.toolTipProvider = { [weak viewModel] identifier in
            viewModel?.summary(ofWordWithKey: identifier)
        }

        let preferenceChanges = Signal.merge(
            measureControl.rx.selectedSegmentIndex.changed.asSignal(onErrorSignalWith: .empty())
                .compactMap { NamingWordMeasure.allCases.indices.contains($0) ? .measure(NamingWordMeasure.allCases[$0]) : nil },
            memberGroupPopUpButton.rx.selectedItemIndex().asSignal(onErrorSignalWith: .empty())
                .map { index in .memberGroup(index > 0 ? NamingMemberGroup.allCases[index - 1] : nil) },
            removesPrefixesItem.rx.click.asSignal().map { [weak self] in .removesPrefixes(!(self?.displayedPreferences.removesPrefixes ?? true)) },
            ignoresCommonWordsItem.rx.click.asSignal().map { [weak self] in .ignoresCommonWords(!(self?.displayedPreferences.ignoresCommonWords ?? true)) },
            mergesCompoundWordsItem.rx.click.asSignal().map { [weak self] in .mergesCompoundWords(!(self?.displayedPreferences.mergesCompoundWords ?? true)) },
            Signal.merge(zip(wordLimitItems, NamingWordCloudPreferences.wordLimitChoices).map { item, wordLimit in
                item.rx.click.asSignal().map { NamingWordCloudPreferenceChange.wordLimit(wordLimit) }
            })
        )

        let rankingClicked: Signal<String?> = rankingTableView.rx.itemClicked()
            .compactMap { [weak rankingTableView] index -> String? in
                guard let rankingTableView, index.row >= 0, index.row < rankingTableView.numberOfRows,
                      let box: DifferentiableBox<NamingWordCloudWord> = try? rankingTableView.rx.model(at: index.row)
                else { return nil }
                return box.model.key
            }
            .asSignal(onErrorSignalWith: .empty())

        let usageClicked: Signal<Int> = usageTableView.rx.itemClicked()
            .compactMap { [weak usageTableView] index -> Int? in
                guard let usageTableView, index.row >= 0, index.row < usageTableView.numberOfRows else { return nil }
                return index.row
            }
            .asSignal(onErrorSignalWith: .empty())

        let rankingColumnClicked: Signal<NamingWordRankingOrder.Column> = rankingTableView.rx.didClickColumn()
            .map { column in column.identifier == .namingWordCloudWord ? .word : .count }
            .asSignal(onErrorSignalWith: .empty())

        let exportRequests = Signal.merge(zip(exportItems, NamingWordCloudExportFormat.allCases).map { item, format in
            item.rx.click.asSignal().map { format }
        })

        let output = viewModel.transform(.init(
            preferenceChanged: preferenceChanges,
            wordSelected: Signal.merge(wordClickedRelay.asSignal(), rankingClicked),
            usageClicked: usageClicked,
            retry: retryButton.rx.click.asSignal(),
            exportRequested: exportRequests,
            compoundWordsRequested: compoundWordsItem.rx.click.asSignal(),
            rankingColumnClicked: rankingColumnClicked
        ))

        setupCanvasControlBindings()

        output.preferences
            .driveOnNext { [weak self] preferences in
                guard let self else { return }
                apply(preferences)
            }
            .disposed(by: rx.disposeBag)

        output.state
            .driveOnNext { [weak self] state in
                guard let self else { return }
                apply(state)
            }
            .disposed(by: rx.disposeBag)

        output.rankingRows
            .map { $0.map(DifferentiableBox.init) }
            .drive(rankingTableView.rx.items) { (tableView: NSTableView, tableColumn: NSTableColumn?, _: Int, box: DifferentiableBox<NamingWordCloudWord>) -> NSView? in
                let appearance = NamingWordCloudRankingCellViewModel(word: box.model).appearance
                if tableColumn?.identifier == .namingWordCloudCount {
                    let cellView = tableView.box.makeView(ofClass: CountCellView.self)
                    cellView.configure(count: appearance.count)
                    return cellView
                }
                let cellView = tableView.box.makeView(ofClass: WordCellView.self)
                cellView.configure(with: appearance)
                return cellView
            }
            .disposed(by: rx.disposeBag)

        // After the rows above: a new order or new counts keep the selected word selected.
        output.rankingRows
            .driveOnNext { [weak self] _ in
                guard let self else { return }
                selectRankingRow(forWordKey: displayedSelectedWordKey, scrollsToRow: false)
            }
            .disposed(by: rx.disposeBag)

        output.rankingOrder
            .driveOnNext { [weak self] rankingOrder in
                guard let self else { return }
                showSortIndicator(for: rankingOrder)
            }
            .disposed(by: rx.disposeBag)

        output.wordCountText
            .drive(wordCountLabel.rx.stringValue)
            .disposed(by: rx.disposeBag)

        output.selectedWordKey
            .distinctUntilChanged()
            .driveOnNext { [weak self] key in
                guard let self else { return }
                displayedSelectedWordKey = key
                wordCloudView.selectedWordIdentifier = key
                if let key, let frame = wordCloudView.frameOfWord(withIdentifier: key) {
                    scroll(toCenterOf: frame, animated: true)
                }
                selectRankingRow(forWordKey: key, scrollsToRow: true)
            }
            .disposed(by: rx.disposeBag)

        output.usageTitle
            .drive(usageTitleLabel.rx.stringValue)
            .disposed(by: rx.disposeBag)

        output.usageDetailColumnTitle
            .driveOnNext { [weak self] title in
                guard let self else { return }
                usageDetailColumn.title = title
            }
            .disposed(by: rx.disposeBag)

        output.usageRows
            .map { $0.map(DifferentiableBox.init) }
            .drive(usageTableView.rx.items) { (tableView: NSTableView, tableColumn: NSTableColumn?, _: Int, box: DifferentiableBox<NamingWordCloudUsageRow>) -> NSView? in
                let cellViewModel = NamingWordCloudUsageCellViewModel(row: box.model)
                let cellView = tableView.box.makeView(ofClass: TextCellView.self)
                if tableColumn?.identifier == .namingWordCloudDetail {
                    cellView.configure(text: cellViewModel.row.detail, isSecondary: true, truncation: .byTruncatingTail)
                } else {
                    cellView.configure(text: cellViewModel.row.name, isSecondary: false, truncation: .byTruncatingMiddle)
                }
                return cellView
            }
            .disposed(by: rx.disposeBag)
    }

    /// The canvas controls act on the scroll view alone, so they stay here
    /// rather than in the view model, like the pinch they stand in for.
    private func setupCanvasControlBindings() {
        canvasControlsView.zoomInButton.rx.click.asSignal()
            .emitOnNext { [weak self] in
                guard let self else { return }
                zoom(by: Self.zoomStep)
            }
            .disposed(by: rx.disposeBag)

        canvasControlsView.zoomOutButton.rx.click.asSignal()
            .emitOnNext { [weak self] in
                guard let self else { return }
                zoom(by: 1 / Self.zoomStep)
            }
            .disposed(by: rx.disposeBag)

        canvasControlsView.zoomLevelButton.rx.click.asSignal()
            .emitOnNext { [weak self] in
                guard let self else { return }
                zoom(by: 1 / cloudScrollView.magnification)
            }
            .disposed(by: rx.disposeBag)

        canvasControlsView.zoomToFitButton.rx.click.asSignal()
            .emitOnNext { [weak self] in
                guard let self else { return }
                zoomToFit(animated: true)
            }
            .disposed(by: rx.disposeBag)

        canvasControlsView.handToolButton.rx.state.asDriver()
            .driveOnNext { [weak self] state in
                guard let self else { return }
                wordCloudView.isHandToolActive = state == .on
            }
            .disposed(by: rx.disposeBag)

        // A pinch, a scroll or a zoom from elsewhere: the zoom level follows.
        Observable.merge(
            NotificationCenter.default.rx.notification(NSScrollView.didEndLiveMagnifyNotification, object: cloudScrollView),
            NotificationCenter.default.rx.notification(NSView.boundsDidChangeNotification, object: cloudScrollView.contentView)
        )
        .asSignal(onErrorSignalWith: .empty())
        .emitOnNext { [weak self] _ in
            guard let self else { return }
            updateMagnificationDisplay()
        }
        .disposed(by: rx.disposeBag)
    }

    // MARK: - Applying the Output

    private func apply(_ preferences: NamingWordCloudPreferences) {
        displayedPreferences = preferences
        measureControl.selectedSegment = NamingWordMeasure.allCases.firstIndex(of: preferences.measure) ?? 0
        memberGroupToolbarItem.isHidden = preferences.measure != .memberWords
        memberGroupPopUpButton.selectItem(at: preferences.memberGroup.flatMap { NamingMemberGroup.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        removesPrefixesItem.state = preferences.removesPrefixes ? .on : .off
        ignoresCommonWordsItem.state = preferences.ignoresCommonWords ? .on : .off
        mergesCompoundWordsItem.state = preferences.mergesCompoundWords ? .on : .off
        for (item, wordLimit) in zip(wordLimitItems, NamingWordCloudPreferences.wordLimitChoices) {
            item.state = wordLimit == preferences.wordLimit ? .on : .off
        }
    }

    private func apply(_ state: NamingWordCloudState) {
        let isReady: Bool
        switch state {
        case .indexingImage(let fractionCompleted):
            showProgress(message: "Indexing \(viewModel?.imageName ?? "the image")…", fractionCompleted: fractionCompleted)
            isReady = false
        case .buildingCorpus(let fractionCompleted):
            showProgress(message: "Building the Find corpus for member names…", fractionCompleted: fractionCompleted)
            isReady = false
        case .ready(let content):
            stateStackView.isHidden = true
            displayedWordCount = content.rankedWords.count
            updateLegend(content.legend)
            if content.cloudWords != displayedCloudWords {
                displayedCloudWords = content.cloudWords
                layoutCloud(content.cloudWords)
            } else {
                updateStatusLine()
            }
            isReady = true
        case .unavailable(let reason):
            showMessage(reason.message, offersRetry: false)
            isReady = false
        case .failed(let message):
            showMessage(message, offersRetry: true)
            isReady = false
        }
        cloudScrollView.isHidden = !isReady
        statusPlatterView.isHidden = !isReady
        canvasControlsView.isHidden = !isReady
        exportItems.forEach { $0.isEnabled = isReady }
    }

    private func layoutCloud(_ words: [NamingWordCloudWord]) {
        layoutTask?.cancel()
        let cloudWords = words.map { word in
            WordCloudView.Word(identifier: word.key, text: word.word, count: word.count, color: word.color.color)
        }
        let canvasColor = ColorDescriptor.namingWordCloudCanvas.color
        wordCloudView.canvasColor = canvasColor
        // Around a canvas zoomed out below the visible area: the same colour, so no edge shows.
        cloudScrollView.backgroundColor = canvasColor
        layoutTask = Task { [weak self] in
            guard let self else { return }
            await wordCloudView.setWords(cloudWords)
        }
    }

    private func showProgress(message: String, fractionCompleted: Double?) {
        stateStackView.isHidden = false
        progressIndicator.isHidden = false
        retryButton.isHidden = true
        messageLabel.stringValue = message
        if let fractionCompleted {
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = fractionCompleted * 100
        } else {
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
        }
    }

    private func showMessage(_ message: String, offersRetry: Bool) {
        stateStackView.isHidden = false
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        retryButton.isHidden = !offersRetry
        messageLabel.stringValue = message
    }

    private func updateLegend(_ categories: [NamingWordCategory]) {
        legendStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for category in categories {
            let dot = DotView(color: ColorDescriptor.namingWordCategory(category).color)
            let label = Label(category.title).then {
                $0.font = .systemFont(ofSize: 11)
                $0.textColor = .secondaryLabelColor
            }
            legendStackView.addArrangedSubview(HStackView(spacing: 4) {
                dot
                label
            })
        }
    }

    private func showSortIndicator(for rankingOrder: NamingWordRankingOrder) {
        let sortedColumn = rankingOrder.column == .word ? rankingWordColumn : rankingCountColumn
        let indicatorName = rankingOrder.isAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
        for column in [rankingWordColumn, rankingCountColumn] {
            rankingTableView.setIndicatorImage(column === sortedColumn ? NSImage(named: NSImage.Name(indicatorName)) : nil, in: column)
        }
        rankingTableView.highlightedTableColumn = sortedColumn
    }

    private func selectRankingRow(forWordKey key: String?, scrollsToRow: Bool) {
        guard let key else {
            rankingTableView.deselectAll(nil)
            return
        }
        guard let row = (0 ..< rankingTableView.numberOfRows).first(where: { row in
            let box: DifferentiableBox<NamingWordCloudWord>? = try? rankingTableView.rx.model(at: row)
            return box?.model.key == key
        }) else { return }
        rankingTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if scrollsToRow {
            rankingTableView.scrollRowToVisible(row)
        }
    }
}

// MARK: - Identifiers

extension NSToolbarItem.Identifier {
    fileprivate static let namingWordCloudMeasure = NSToolbarItem.Identifier("NamingWordCloud.measure")
    fileprivate static let namingWordCloudMemberGroup = NSToolbarItem.Identifier("NamingWordCloud.memberGroup")
    fileprivate static let namingWordCloudOptions = NSToolbarItem.Identifier("NamingWordCloud.options")
    fileprivate static let namingWordCloudExport = NSToolbarItem.Identifier("NamingWordCloud.export")
    fileprivate static let namingWordCloudInspectorSeparator = NSToolbarItem.Identifier("NamingWordCloud.inspectorSeparator")
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let namingWordCloudWord = NSUserInterfaceItemIdentifier("NamingWordCloud.word")
    fileprivate static let namingWordCloudCount = NSUserInterfaceItemIdentifier("NamingWordCloud.count")
    fileprivate static let namingWordCloudName = NSUserInterfaceItemIdentifier("NamingWordCloud.name")
    fileprivate static let namingWordCloudDetail = NSUserInterfaceItemIdentifier("NamingWordCloud.detail")
}

// MARK: - Cells

extension NamingWordCloudViewController {
    /// A dot of a category's colour, for the legend and the ranking.
    fileprivate final class DotView: NSView {
        private let color: NSColor

        init(color: NSColor) {
            self.color = color
            super.init(frame: .zero)
            snp.makeConstraints { make in
                make.size.equalTo(8)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }

    /// The ranking's Word column: the word after a dot of its category's colour.
    fileprivate final class WordCellView: TableCellView {
        private let dotContainerView = NSView()

        private let wordLabel = Label().then {
            $0.lineBreakMode = .byTruncatingTail
        }

        private var currentDotView: DotView?

        override func setup() {
            super.setup()
            hierarchy {
                dotContainerView
                wordLabel
            }
            dotContainerView.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
                make.size.equalTo(8)
            }
            wordLabel.snp.makeConstraints { make in
                make.leading.equalTo(dotContainerView.snp.trailing).offset(6)
                make.trailing.lessThanOrEqualToSuperview().inset(2)
                make.centerY.equalToSuperview()
            }
        }

        func configure(with appearance: NamingWordCloudRankingCellViewModel.Appearance) {
            wordLabel.stringValue = appearance.word
            currentDotView?.removeFromSuperview()
            let dot = DotView(color: appearance.dotColor.color)
            dotContainerView.hierarchy { dot }
            dot.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            currentDotView = dot
        }
    }

    /// The ranking's Count column, right-aligned in digits of one width.
    fileprivate final class CountCellView: TableCellView {
        private let countLabel = Label().then {
            $0.alignment = .right
            $0.textColor = .secondaryLabelColor
            $0.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        override func setup() {
            super.setup()
            hierarchy {
                countLabel
            }
            countLabel.snp.makeConstraints { make in
                make.leading.greaterThanOrEqualToSuperview().inset(2)
                make.trailing.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
            }
        }

        func configure(count: String) {
            countLabel.stringValue = count
        }
    }

    /// A column of the usage list: a name, or its kind or declaring type.
    fileprivate final class TextCellView: TableCellView {
        private let textLabel = Label()

        override func setup() {
            super.setup()
            hierarchy {
                textLabel
            }
            textLabel.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
            }
        }

        func configure(text: String, isSecondary: Bool, truncation: NSLineBreakMode) {
            textLabel.stringValue = text
            textLabel.textColor = isSecondary ? .secondaryLabelColor : .labelColor
            textLabel.lineBreakMode = truncation
        }
    }
}
