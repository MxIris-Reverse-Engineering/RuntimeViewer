import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SnapKit

/// The Inspector's References tab: who calls the member at the content pane's insertion point,
/// what it calls, and which functions use the type on screen — a section each, one level deep and in
/// the object's own image, with Show in Find Navigator for the whole tree across every indexed image.
/// The sections share the Inspector's height below the title (`StackedHeightSharing`): a list whose
/// rows fit takes just that, and the lists that do not split the rest down to the Inspector's bottom,
/// each scrolling inside its share. The page itself scrolls only when the Inspector is too short for
/// every list's first few rows.
final class InspectorReferencesViewController: BaseEffectViewController<InspectorReferencesViewModel> {
    private let headerLabel = Label()

    /// `In AppKit`: the image the sections read.
    private let scopeLabel = Label()

    /// What the calls need when the insertion point is on no member's line.
    private let hintLabel = Label(wrappingLabelWithString: "Put the insertion point on a method or property to see its callers and callees.")

    private let callersSectionView = SectionView(section: .callers)

    private let calleesSectionView = SectionView(section: .callees)

    private let typeReferencesSectionView = SectionView(section: .typeReferences)

    private lazy var sectionsView = SectionsView(sectionViews: [callersSectionView, calleesSectionView, typeReferencesSectionView])

    private let pageScrollView = ScrollView()

    /// The title and the hint, above the sections.
    private lazy var topStackView = VStackView(alignment: .leading, spacing: 16) {
        VStackView(alignment: .leading, spacing: 2) {
            headerLabel
            scopeLabel
        }
        hintLabel
    }

    override var containerViewUsingSafeArea: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()

        let documentView = FlippedView()
        documentView.hierarchy {
            topStackView
            sectionsView
        }
        pageScrollView.documentView = documentView
        containerView.hierarchy {
            pageScrollView
        }

        // At the page's top edge: the tab switcher leaves the gap above the page (`TabViewController.pageTopSpacing`).
        pageScrollView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }

        // As tall as the Inspector, which the sections share; taller only when even their smallest
        // heights do not fit, and the page scrolls then.
        documentView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.width.equalTo(pageScrollView.contentView)
            make.height.greaterThanOrEqualTo(pageScrollView.contentView)
            make.height.equalTo(pageScrollView.contentView).priority(.low)
        }

        topStackView.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(8)
        }

        sectionsView.snp.makeConstraints { make in
            make.top.equalTo(topStackView.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(8)
            make.bottom.equalToSuperview().inset(8)
        }

        // The title and the hint keep their own height; the sections take the rest.
        topStackView.setHuggingPriority(.defaultHigh, for: .vertical)

        pageScrollView.do {
            $0.drawsBackground = false
            $0.hasVerticalScroller = true
            $0.hasHorizontalScroller = false
            $0.autohidesScrollers = true
            $0.borderType = .noBorder
        }

        headerLabel.do {
            $0.font = .systemFont(ofSize: 13, weight: .semibold)
            $0.textColor = .labelColor
            $0.maximumNumberOfLines = 2
            $0.lineBreakMode = .byTruncatingMiddle
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        scopeLabel.do {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
            $0.toolTip = "Show in Find Navigator searches every indexed image"
        }

        hintLabel.do {
            $0.textColor = .secondaryLabelColor
            $0.font = .systemFont(ofSize: 11)
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
    }

    override func setupBindings(for viewModel: InspectorReferencesViewModel) {
        super.setupBindings(for: viewModel)

        let sectionViews = [callersSectionView, calleesSectionView, typeReferencesSectionView]
        let input = InspectorReferencesViewModel.Input(
            rowClicked: Signal.merge(sectionViews.map(\.rowClicked)),
            showInFindNavigatorClicked: Signal.merge(sectionViews.map { sectionView in
                sectionView.showInFindNavigatorButton.rx.click.asSignal().map { sectionView.section }
            }),
            // Nothing is asked while the tab is off screen.
            isVisible: Observable.merge(rx.viewWillAppear.map { true }, rx.viewWillDisappear.map { false })
                .asDriver(onErrorJustReturn: false)
        )
        let output = viewModel.transform(input)

        output.subjectTitle.drive(headerLabel.rx.stringValue).disposed(by: rx.disposeBag)
        output.scopeTitle.drive(scopeLabel.rx.stringValue).disposed(by: rx.disposeBag)

        for (sectionView, state) in [(callersSectionView, output.callers), (calleesSectionView, output.callees), (typeReferencesSectionView, output.typeReferences)] {
            sectionView.bind(to: state, disposedBy: rx.disposeBag)
        }

        // The hint stands in for the two call sections while there is no member to ask about.
        output.callers.driveOnNext { [weak self] state in
            guard let self else { return }
            if case .unavailable = state {
                hintLabel.isHidden = false
            } else {
                hintLabel.isHidden = true
            }
        }
        .disposed(by: rx.disposeBag)
    }
}

// MARK: - Sections View

extension InspectorReferencesViewController {
    /// The sections, one under another, sharing the height the title and the hint leave them
    /// (`StackedHeightSharing`). It lays them out itself: how tall one is depends on what the others
    /// list. Never shorter than every section at its smallest, so the page scrolls instead.
    private final class SectionsView: NSView {
        private let sectionViews: [SectionView]

        private static let spacing: CGFloat = 16

        override var isFlipped: Bool { true }

        init(sectionViews: [SectionView]) {
            self.sectionViews = sectionViews
            super.init(frame: .zero)

            for sectionView in sectionViews {
                addSubview(sectionView)
                sectionView.contentDidChange = { [weak self] in
                    guard let self else { return }
                    invalidateIntrinsicContentSize()
                    needsLayout = true
                }
            }

            // Stretched to whatever the page leaves, never squeezed below the sections' smallest heights.
            setContentHuggingPriority(.init(1), for: .vertical)
            setContentCompressionResistancePriority(.required, for: .vertical)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var intrinsicContentSize: NSSize {
            // A message's height depends on the width, which the first layout pass has yet to set.
            guard bounds.width > 0 else {
                return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
            }
            let demands = visibleSectionViews.map { $0.heightDemand(forWidth: bounds.width) }
            return NSSize(width: NSView.noIntrinsicMetric, height: StackedHeightSharing.minimumHeight(of: demands, spacing: Self.spacing))
        }

        override func setFrameSize(_ newSize: NSSize) {
            let widthChanged = newSize.width != frame.width
            super.setFrameSize(newSize)
            // A message wraps onto more lines in a narrower section.
            if widthChanged {
                invalidateIntrinsicContentSize()
            }
        }

        override func layout() {
            super.layout()

            let visibleSectionViews = self.visibleSectionViews
            let heights = StackedHeightSharing.heights(
                for: visibleSectionViews.map { $0.heightDemand(forWidth: bounds.width) },
                spacing: Self.spacing,
                in: bounds.height
            )
            var top: CGFloat = 0
            for (sectionView, height) in zip(visibleSectionViews, heights) {
                let bottom = top + height
                // On whole points, so that no edge falls between two pixels.
                sectionView.frame = NSRect(x: 0, y: top.rounded(), width: bounds.width, height: bottom.rounded() - top.rounded())
                top = bottom + Self.spacing
            }
        }

        private var visibleSectionViews: [SectionView] {
            sectionViews.filter { !$0.isHidden }
        }
    }
}

// MARK: - Section View

extension InspectorReferencesViewController {
    /// One section: its title and count, Show in Find Navigator, and a list one level deep — or, while
    /// there is none, the loading placeholder or a message. `SectionsView` gives it its height from
    /// `heightDemand(forWidth:)`; the list fills what the title leaves and scrolls past that.
    private final class SectionView: NSView {
        let section: InspectorReferencesViewModel.Section

        /// Called after the section shows something else, so that the sections are laid out again.
        var contentDidChange: (() -> Void)?

        private let titleLabel = Label()

        private let countLabel = Label()

        let showInFindNavigatorButton = NSButton()

        private lazy var titleRow = HStackView(spacing: 6) {
            titleLabel
            countLabel
            NSView()
            showInFindNavigatorButton
        }

        private let (scrollView, tableView) = SelfSizingTableView.scrollableNavigationListTableView()

        private let statusLabel = Label(wrappingLabelWithString: "")

        private let skeletonPlaceholderView = SkeletonPlaceholderView.runtimeObjectList()

        private let rowsRelay = BehaviorRelay<[InspectorReferenceCellViewModel]>(value: [])

        /// How far a list is cut down before the page scrolls instead: three or four rows, the floor
        /// a navigation list has anyway (`scrollableNavigationListTableView()`).
        private static let minimumListHeight: CGFloat = 80

        /// Between the title and the list or the message.
        private static let contentSpacing: CGFloat = 6

        /// Between the title and the loading placeholder.
        private static let placeholderSpacing: CGFloat = 8

        /// A row clicked, as the model it shows.
        var rowClicked: Signal<InspectorReferenceCellViewModel> {
            tableView.rx.itemClicked()
                .compactMap { [weak tableView] index -> InspectorReferenceCellViewModel? in
                    guard let tableView, index.row >= 0, index.row < tableView.numberOfRows else { return nil }
                    return try? tableView.rx.model(at: index.row)
                }
                .asSignal(onErrorSignalWith: .empty())
        }

        init(section: InspectorReferencesViewModel.Section) {
            self.section = section
            super.init(frame: .zero)

            hierarchy {
                titleRow
                scrollView
                statusLabel
                skeletonPlaceholderView
            }

            titleRow.snp.makeConstraints { make in
                make.top.leading.trailing.equalToSuperview()
            }

            scrollView.snp.makeConstraints { make in
                make.top.equalTo(titleRow.snp.bottom).offset(Self.contentSpacing)
                make.leading.trailing.bottom.equalToSuperview()
            }

            statusLabel.snp.makeConstraints { make in
                make.top.equalTo(titleRow.snp.bottom).offset(Self.contentSpacing)
                make.leading.trailing.equalToSuperview()
                make.bottom.lessThanOrEqualToSuperview()
            }

            skeletonPlaceholderView.snp.makeConstraints { make in
                make.top.equalTo(titleRow.snp.bottom).offset(Self.placeholderSpacing)
                make.leading.trailing.equalToSuperview()
                make.bottom.lessThanOrEqualToSuperview().priority(.high)
            }

            titleLabel.do {
                $0.stringValue = section.title
                $0.font = .systemFont(ofSize: 11, weight: .semibold)
                $0.textColor = .secondaryLabelColor
            }

            countLabel.do {
                $0.font = .systemFont(ofSize: 11)
                $0.textColor = .tertiaryLabelColor
            }

            showInFindNavigatorButton.do {
                $0.image = SFSymbols(systemName: .arrowRightCircle).nsuiImgae
                $0.imagePosition = .imageOnly
                $0.isBordered = false
                $0.bezelStyle = .accessoryBarAction
                $0.toolTip = "Show in Find Navigator"
                $0.setAccessibilityLabel("Show in Find Navigator")
            }

            statusLabel.do {
                $0.font = .systemFont(ofSize: 11)
                $0.textColor = .secondaryLabelColor
                $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }

            tableView.do {
                $0.intercellSpacing = .init(width: 0, height: 2)
                // The rows never wrap, so they are all one height, and the list knows exactly how
                // tall its rows are before any is drawn.
                $0.usesAutomaticRowHeights = false
                $0.rowHeight = FindResultCellView.singleLineRowHeight(for: .inspector)
            }

            rowsRelay
                .asDriver()
                .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: InspectorReferenceCellViewModel) -> NSView? in
                    let cellView = tableView.box.makeView(ofClass: FindResultCellView.self) {
                        FindResultCellView(metrics: .inspector)
                    }
                    cellView.configure(with: cellViewModel.appearance)
                    return cellView
                }
                .disposed(by: rx.disposeBag)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func bind(to state: Driver<InspectorReferencesViewModel.SectionState>, disposedBy disposeBag: DisposeBag) {
            state.driveOnNext { [weak self] state in
                guard let self else { return }
                apply(state)
            }
            .disposed(by: disposeBag)
        }

        /// What the section asks of the height at `width`: its title, then everything it lists. A list
        /// gives up all but `minimumListHeight` and scrolls; the loading placeholder and a message are
        /// never cut. Measured from the parts' own sizes, not by a layout pass: the sections ask for
        /// it while they are being laid out.
        func heightDemand(forWidth width: CGFloat) -> StackedHeightSharing.Demand {
            // The row is as tall as its tallest control.
            let titleControls: [NSView] = [titleLabel, countLabel, showInFindNavigatorButton]
            let titleHeight = titleControls.map(\.intrinsicContentSize.height).max() ?? 0
            if skeletonPlaceholderView.isPresentingPlaceholder {
                let height = titleHeight + Self.placeholderSpacing + skeletonPlaceholderView.contentHeight
                return StackedHeightSharing.Demand(minimum: height, preferred: height)
            }
            if !scrollView.isHidden {
                let listHeight = tableView.intrinsicContentSize.height
                return StackedHeightSharing.Demand(
                    minimum: titleHeight + Self.contentSpacing + min(listHeight, Self.minimumListHeight),
                    preferred: titleHeight + Self.contentSpacing + listHeight
                )
            }
            let messageBounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
            let messageHeight = statusLabel.cell?.cellSize(forBounds: messageBounds).height ?? 0
            let height = titleHeight + Self.contentSpacing + messageHeight
            return StackedHeightSharing.Demand(minimum: height, preferred: height)
        }

        private func apply(_ state: InspectorReferencesViewModel.SectionState) {
            switch state {
            case .unavailable:
                isHidden = true
                skeletonPlaceholderView.isPresentingPlaceholder = false
            case .loading:
                isHidden = false
                countLabel.stringValue = ""
                statusLabel.stringValue = ""
                scrollView.isHidden = true
                skeletonPlaceholderView.isPresentingPlaceholder = true
            case .loaded(let rows, let totalCount):
                isHidden = false
                skeletonPlaceholderView.isPresentingPlaceholder = false
                rowsRelay.accept(rows)
                countLabel.stringValue = rows.count < totalCount ? "\(rows.count) of \(totalCount)" : "\(totalCount)"
                scrollView.isHidden = rows.isEmpty
                statusLabel.stringValue = rows.isEmpty ? "None found" : ""
            case .failed(let message):
                isHidden = false
                skeletonPlaceholderView.isPresentingPlaceholder = false
                rowsRelay.accept([])
                countLabel.stringValue = ""
                scrollView.isHidden = true
                statusLabel.stringValue = message
            }
            contentDidChange?()
        }
    }

    /// The page's document view: laid out from the top down.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
