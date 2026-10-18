import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SnapKit

/// The Inspector's References tab: who calls the member at the content pane's insertion point,
/// what it calls, and which functions use the type on screen — a section each, one level deep and in
/// the object's own image, with Show in Find Navigator for the whole tree across every indexed image. The
/// sections stack in a page that scrolls; each list grows to fit its rows up to a cap and scrolls
/// inside it past that.
final class InspectorReferencesViewController: BaseEffectViewController<InspectorReferencesViewModel> {
    private let headerLabel = Label()

    /// `In AppKit`: the image the sections read.
    private let scopeLabel = Label()

    /// What the calls need when the insertion point is on no member's line.
    private let hintLabel = Label(wrappingLabelWithString: "Put the insertion point on a method or property to see its callers and callees.")

    private let callersSectionView = SectionView(section: .callers)

    private let calleesSectionView = SectionView(section: .callees)

    private let typeReferencesSectionView = SectionView(section: .typeReferences)

    private let pageScrollView = ScrollView()

    private lazy var pageStackView = VStackView(alignment: .leading, spacing: 16) {
        VStackView(alignment: .leading, spacing: 2) {
            headerLabel
            scopeLabel
        }
        hintLabel
        callersSectionView
        calleesSectionView
        typeReferencesSectionView
    }

    override var containerViewUsingSafeArea: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()

        let documentView = FlippedView()
        documentView.hierarchy {
            pageStackView
        }
        pageScrollView.documentView = documentView
        containerView.hierarchy {
            pageScrollView
        }

        // At the page's top edge: the tab switcher leaves the gap above the page (`TabViewController.pageTopSpacing`).
        pageScrollView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }

        documentView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.width.equalTo(pageScrollView.contentView)
        }

        pageStackView.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(8)
            make.bottom.equalToSuperview().inset(8)
        }

        for sectionView in [callersSectionView, calleesSectionView, typeReferencesSectionView] {
            sectionView.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview()
            }
        }

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

// MARK: - Section View

extension InspectorReferencesViewController {
    /// One section: its title and count, Show in Find Navigator, and a list one level deep that
    /// grows to fit its rows up to `maximumListHeight`.
    private final class SectionView: NSView {
        let section: InspectorReferencesViewModel.Section

        private let titleLabel = Label()

        private let countLabel = Label()

        let showInFindNavigatorButton = NSButton()

        private let (scrollView, tableView) = SelfSizingTableView.scrollableNavigationListTableView()

        private let statusLabel = Label(wrappingLabelWithString: "")

        private let skeletonPlaceholderView = SkeletonPlaceholderView.runtimeObjectList()

        private let rowsRelay = BehaviorRelay<[InspectorReferenceCellViewModel]>(value: [])

        /// The list's cap: past it the rows scroll inside the section.
        private static let maximumListHeight: CGFloat = 240

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

            let titleRow = HStackView(spacing: 6) {
                titleLabel
                countLabel
                NSView()
                showInFindNavigatorButton
            }
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
                make.top.equalTo(titleRow.snp.bottom).offset(6)
                make.leading.trailing.bottom.equalToSuperview()
            }

            statusLabel.snp.makeConstraints { make in
                make.top.equalTo(titleRow.snp.bottom).offset(6)
                make.leading.trailing.equalToSuperview()
                make.bottom.lessThanOrEqualToSuperview()
            }

            skeletonPlaceholderView.snp.makeConstraints { make in
                make.top.equalTo(titleRow.snp.bottom).offset(8)
                make.leading.trailing.equalToSuperview()
                make.bottom.lessThanOrEqualToSuperview().priority(.high)
            }

            scrollView.maximumContentSize = NSSize(width: NSView.noIntrinsicMetric, height: Self.maximumListHeight)

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
            }

            rowsRelay
                .asDriver()
                .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: InspectorReferenceCellViewModel) -> NSView? in
                    let cellView = tableView.box.makeView(ofClass: FindResultCellView.self)
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
        }
    }

    /// The page's document view: laid out from the top down.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
