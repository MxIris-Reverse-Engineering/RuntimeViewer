import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import SnapKit

/// The naming word cloud window's content: the measure control and the ⚙︎ and
/// Export menus along the top; the cloud on a canvas far larger than the
/// window on the left, with its status line and legend; the ranking of every
/// word above the names holding the selected one on the right
/// (proposal `naming-word-cloud`).
final class NamingWordCloudViewController: BaseViewController<NamingWordCloudViewModel> {
    // MARK: - Relays

    /// Clicks on words of the cloud, which is drawn rather than built of controls.
    private let wordClickedRelay = PublishRelay<String?>()

    // MARK: - Top Bar

    private let measureControl = NSSegmentedControl(
        labels: NamingWordMeasure.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    private let memberGroupPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false).then {
        $0.addItems(withTitles: ["All Members"] + NamingMemberGroup.allCases.map(\.title))
        $0.controlSize = .small
    }

    private let settingsPopUpButton = NSPopUpButton(frame: .zero, pullsDown: true)

    private let exportPopUpButton = NSPopUpButton(frame: .zero, pullsDown: true)

    private let removesPrefixesItem = NSMenuItem(title: "Remove Prefixes", action: nil, keyEquivalent: "")

    private let ignoresCommonWordsItem = NSMenuItem(title: "Ignore Common Words", action: nil, keyEquivalent: "")

    private let mergesCompoundWordsItem = NSMenuItem(title: "Merge Compound Words", action: nil, keyEquivalent: "")

    private let wordLimitItems: [NSMenuItem] = NamingWordCloudPreferences.wordLimitChoices.map { wordLimit in
        NSMenuItem(title: wordLimit.map { "\($0.formatted()) Words" } ?? "All Words", action: nil, keyEquivalent: "")
    }

    private let compoundWordsItem = NSMenuItem(title: "Compound Words…", action: nil, keyEquivalent: "")

    private let zoomToFitItem = NSMenuItem(title: "Zoom to Fit", action: nil, keyEquivalent: "")

    private let actualSizeItem = NSMenuItem(title: "Actual Size", action: nil, keyEquivalent: "")

    private let exportItems: [NSMenuItem] = NamingWordCloudExportFormat.allCases.map {
        NSMenuItem(title: $0.menuTitle, action: nil, keyEquivalent: "")
    }

    // MARK: - Cloud

    private let wordCloudView = WordCloudView(frame: .zero)

    private let cloudScrollView = ScrollView().then {
        $0.hasHorizontalScroller = true
        $0.hasVerticalScroller = true
        $0.autohidesScrollers = true
        $0.allowsMagnification = true
        $0.minMagnification = 0.1
        $0.maxMagnification = 4
        $0.drawsBackground = false
    }

    /// The status line and the legend, over a translucent plate so that words
    /// scrolling under it stay legible.
    private let statusPlate = NSVisualEffectView().then {
        $0.material = .hudWindow
        $0.blendingMode = .withinWindow
        $0.state = .active
        $0.wantsLayer = true
        $0.layer?.cornerRadius = 6
    }

    private let statusLabel = Label().then {
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .secondaryLabelColor
    }

    /// Filled with the legend's entries whenever the cloud's categories change.
    private let legendStackView = HStackView(spacing: 10) {}

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

    // MARK: - Ranking and Usages

    private let (rankingScrollView, rankingTableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()

    private let usageTitleLabel = Label().then {
        $0.font = .systemFont(ofSize: 12, weight: .semibold)
        $0.lineBreakMode = .byTruncatingTail
    }

    private let (usageScrollView, usageTableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()

    private let mainSplitView = NSSplitView().then {
        $0.isVertical = true
        $0.dividerStyle = .thin
    }

    private let sideSplitView = NSSplitView().then {
        $0.isVertical = false
        $0.dividerStyle = .thin
    }

    // MARK: - State

    private var displayedPreferences = NamingWordCloudPreferences()

    private var displayedCloudWords: [NamingWordCloudWord] = []

    private var displayedWordCount = 0

    private var hasCenteredCanvas = false

    private var layoutTask: Task<Void, Never>?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        settingsPopUpButton.menu = NSMenu().then { menu in
            // A pull-down shows its first item as its title.
            menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: "").then {
                $0.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            })
            menu.addItem(removesPrefixesItem)
            menu.addItem(ignoresCommonWordsItem)
            menu.addItem(mergesCompoundWordsItem)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Words in the Cloud"))
            wordLimitItems.forEach(menu.addItem)
            menu.addItem(.separator())
            menu.addItem(compoundWordsItem)
            menu.addItem(.separator())
            menu.addItem(zoomToFitItem)
            menu.addItem(actualSizeItem)
        }
        exportPopUpButton.menu = NSMenu().then { menu in
            menu.addItem(NSMenuItem(title: "Export", action: nil, keyEquivalent: ""))
            exportItems.forEach(menu.addItem)
        }

        let topBar = HStackView(spacing: 8) {
            measureControl
            memberGroupPopUpButton
            NSView()
            settingsPopUpButton
            exportPopUpButton
        }

        cloudScrollView.documentView = wordCloudView
        let cloudContainerView = NSView()
        cloudContainerView.hierarchy {
            cloudScrollView
            statusPlate
            stateStackView
        }
        statusPlate.hierarchy {
            HStackView(spacing: 12) {
                statusLabel
                legendStackView
            }
            .then { stack in
                stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            }
        }

        let usageContainerView = NSView()
        usageContainerView.hierarchy {
            usageTitleLabel
            usageScrollView
        }

        sideSplitView.addArrangedSubview(rankingScrollView)
        sideSplitView.addArrangedSubview(usageContainerView)
        mainSplitView.addArrangedSubview(cloudContainerView)
        mainSplitView.addArrangedSubview(sideSplitView)

        containerView.hierarchy {
            topBar
            mainSplitView
        }

        topBar.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(8)
            make.leading.trailing.equalToSuperview().inset(12)
        }
        mainSplitView.snp.makeConstraints { make in
            make.top.equalTo(topBar.snp.bottom).offset(8)
            make.leading.trailing.bottom.equalToSuperview()
        }
        cloudScrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        statusPlate.snp.makeConstraints { make in
            make.leading.bottom.equalToSuperview().inset(10)
            make.trailing.lessThanOrEqualToSuperview().inset(10)
        }
        statusPlate.subviews.first?.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        stateStackView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.lessThanOrEqualTo(360)
        }
        progressIndicator.snp.makeConstraints { make in
            make.width.equalTo(200)
        }
        usageTitleLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(8)
        }
        usageScrollView.snp.makeConstraints { make in
            make.top.equalTo(usageTitleLabel.snp.bottom).offset(6)
            make.leading.trailing.bottom.equalToSuperview()
        }
        cloudContainerView.snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(360)
        }
        sideSplitView.snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(220)
        }

        wordCloudView.wordClickHandler = { [weak self] identifier in
            guard let self else { return }
            wordClickedRelay.accept(identifier)
        }
        wordCloudView.layoutCompletionHandler = { [weak self] in
            guard let self else { return }
            updateStatusLine()
            centerCanvasIfNeeded()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        mainSplitView.setPosition(mainSplitView.bounds.width * 0.7, ofDividerAt: 0)
        sideSplitView.setPosition(sideSplitView.bounds.height * 0.5, ofDividerAt: 0)
    }

    // MARK: - Canvas

    /// The PNG of the whole canvas; see `WordCloudView.pngDataOfWholeCanvas`.
    func wordCloudPNGData() -> Data? {
        wordCloudView.pngDataOfWholeCanvas()
    }

    private func zoomToFit() {
        let canvasSize = wordCloudView.bounds.size
        let visibleSize = cloudScrollView.contentView.bounds.size
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let magnification = min(cloudScrollView.magnification * visibleSize.width / canvasSize.width, cloudScrollView.magnification * visibleSize.height / canvasSize.height)
        cloudScrollView.animator().setMagnification(max(cloudScrollView.minMagnification, magnification), centeredAt: NSPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }

    private func centerCanvasIfNeeded() {
        guard !hasCenteredCanvas, wordCloudView.bounds.width > 0 else { return }
        hasCenteredCanvas = true
        scroll(toCenterOf: wordCloudView.bounds, animated: false)
    }

    private func scroll(toCenterOf rect: CGRect, animated: Bool) {
        let clipView = cloudScrollView.contentView
        let visibleSize = clipView.bounds.size
        let origin = NSPoint(x: rect.midX - visibleSize.width / 2, y: rect.midY - visibleSize.height / 2)
        let constrained = clipView.constrainBoundsRect(NSRect(origin: origin, size: visibleSize)).origin
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                clipView.animator().setBoundsOrigin(constrained)
            }
        } else {
            clipView.setBoundsOrigin(constrained)
        }
        cloudScrollView.reflectScrolledClipView(clipView)
    }

    private func updateStatusLine() {
        let placed = wordCloudView.placedWordCount
        statusLabel.stringValue = "Showing \(placed.formatted()) of \(displayedWordCount.formatted()) words"
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

        let exportRequests = Signal.merge(zip(exportItems, NamingWordCloudExportFormat.allCases).map { item, format in
            item.rx.click.asSignal().map { format }
        })

        let output = viewModel.transform(.init(
            preferenceChanged: preferenceChanges,
            wordSelected: Signal.merge(wordClickedRelay.asSignal(), rankingClicked),
            usageClicked: usageClicked,
            retry: retryButton.rx.click.asSignal(),
            exportRequested: exportRequests,
            compoundWordsRequested: compoundWordsItem.rx.click.asSignal()
        ))

        zoomToFitItem.rx.click.asSignal()
            .emitOnNext { [weak self] in
                guard let self else { return }
                zoomToFit()
            }
            .disposed(by: rx.disposeBag)

        actualSizeItem.rx.click.asSignal()
            .emitOnNext { [weak self] in
                guard let self else { return }
                cloudScrollView.animator().magnification = 1
            }
            .disposed(by: rx.disposeBag)

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

        output.state
            .map { state -> [DifferentiableBox<NamingWordCloudWord>] in
                guard case .ready(let content) = state else { return [] }
                return content.rankedWords.map(DifferentiableBox.init)
            }
            .distinctUntilChanged()
            .drive(rankingTableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, box: DifferentiableBox<NamingWordCloudWord>) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: RankingCellView.self)
                cellView.configure(with: NamingWordCloudRankingCellViewModel(word: box.model))
                return cellView
            }
            .disposed(by: rx.disposeBag)

        output.selectedWordKey
            .distinctUntilChanged()
            .driveOnNext { [weak self] key in
                guard let self else { return }
                wordCloudView.selectedWordIdentifier = key
                if let key, let frame = wordCloudView.frameOfWord(withIdentifier: key) {
                    scroll(toCenterOf: frame, animated: true)
                }
                selectRankingRow(forWordKey: key)
            }
            .disposed(by: rx.disposeBag)

        output.usageTitle
            .drive(usageTitleLabel.rx.stringValue)
            .disposed(by: rx.disposeBag)

        output.usageRows
            .map { $0.map(DifferentiableBox.init) }
            .drive(usageTableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, box: DifferentiableBox<NamingWordCloudUsageRow>) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: UsageCellView.self)
                cellView.configure(with: NamingWordCloudUsageCellViewModel(row: box.model))
                return cellView
            }
            .disposed(by: rx.disposeBag)
    }

    // MARK: - Applying the Output

    private func apply(_ preferences: NamingWordCloudPreferences) {
        displayedPreferences = preferences
        measureControl.selectedSegment = NamingWordMeasure.allCases.firstIndex(of: preferences.measure) ?? 0
        memberGroupPopUpButton.isHidden = preferences.measure != .memberWords
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
                layOutCloud(content.cloudWords)
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
        statusPlate.isHidden = !isReady
        exportItems.forEach { $0.isEnabled = isReady }
    }

    private func layOutCloud(_ words: [NamingWordCloudWord]) {
        layoutTask?.cancel()
        let cloudWords = words.map { word in
            WordCloudView.Word(identifier: word.key, text: word.word, count: word.count, color: word.color.color)
        }
        wordCloudView.canvasColor = ColorDescriptor.namingWordCloudCanvas.color
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

    private func selectRankingRow(forWordKey key: String?) {
        guard let key else {
            rankingTableView.deselectAll(nil)
            return
        }
        guard let row = (0 ..< rankingTableView.numberOfRows).first(where: { row in
            let box: DifferentiableBox<NamingWordCloudWord>? = try? rankingTableView.rx.model(at: row)
            return box?.model.key == key
        }) else { return }
        rankingTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        rankingTableView.scrollRowToVisible(row)
    }
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

    fileprivate final class RankingCellView: TableCellView {
        private let dotContainerView = NSView()

        private let wordLabel = Label().then {
            $0.lineBreakMode = .byTruncatingTail
        }

        private let countLabel = Label().then {
            $0.alignment = .right
            $0.textColor = .secondaryLabelColor
            $0.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        private var currentDotView: DotView?

        override func setup() {
            super.setup()
            hierarchy {
                dotContainerView
                wordLabel
                countLabel
            }
            dotContainerView.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
                make.size.equalTo(8)
            }
            wordLabel.snp.makeConstraints { make in
                make.leading.equalTo(dotContainerView.snp.trailing).offset(6)
                make.centerY.equalToSuperview()
            }
            countLabel.snp.makeConstraints { make in
                make.leading.greaterThanOrEqualTo(wordLabel.snp.trailing).offset(8)
                make.trailing.equalToSuperview().inset(6)
                make.centerY.equalToSuperview()
            }
            countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        func configure(with cellViewModel: NamingWordCloudRankingCellViewModel) {
            let appearance = cellViewModel.appearance
            wordLabel.stringValue = appearance.word
            countLabel.stringValue = appearance.count
            currentDotView?.removeFromSuperview()
            let dot = DotView(color: appearance.dotColor.color)
            dotContainerView.hierarchy { dot }
            dot.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            currentDotView = dot
        }
    }

    fileprivate final class UsageCellView: TableCellView {
        private let nameLabel = Label().then {
            $0.lineBreakMode = .byTruncatingMiddle
        }

        private let detailLabel = Label().then {
            $0.alignment = .right
            $0.textColor = .secondaryLabelColor
            $0.lineBreakMode = .byTruncatingTail
        }

        override func setup() {
            super.setup()
            hierarchy {
                nameLabel
                detailLabel
            }
            nameLabel.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(6)
                make.centerY.equalToSuperview()
            }
            detailLabel.snp.makeConstraints { make in
                make.leading.greaterThanOrEqualTo(nameLabel.snp.trailing).offset(8)
                make.trailing.equalToSuperview().inset(6)
                make.centerY.equalToSuperview()
            }
            nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        func configure(with cellViewModel: NamingWordCloudUsageCellViewModel) {
            nameLabel.stringValue = cellViewModel.row.name
            detailLabel.stringValue = cellViewModel.row.detail
        }
    }
}
