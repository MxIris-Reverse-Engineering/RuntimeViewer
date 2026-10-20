import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

/// The Hierarchy page of a protocol: the protocol, and under it the protocols
/// it refines, each with the ones it refines in turn, as an outline with every
/// level expanded. A protocol can refine several, so the levels form a tree,
/// where a class's form the chain `InspectorClassViewController` lists. Laid
/// out like that page and the Relationships page, with the same rows.
final class InspectorProtocolViewController: BaseEffectViewController<InspectorHierarchyViewModel> {
    private let headerLabel = Label()

    private let (scrollView, outlineView): (SelfSizingScrollView, SelfSizingOutlineView) = SelfSizingOutlineView.scrollableSingleColumnOutlineView()

    private let skeletonPlaceholderView = SkeletonPlaceholderView.runtimeObjectList()

    override var containerViewUsingSafeArea: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.hierarchy {
            headerLabel
            scrollView
            skeletonPlaceholderView
        }

        // At the page's top edge: the tab switcher leaves the gap above the page (`TabViewController.pageTopSpacing`).
        headerLabel.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(8)
        }

        // As tall as its expanded levels, and no taller than the pane: past
        // that the outline scrolls.
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerLabel.snp.bottom).offset(8)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            make.bottom.lessThanOrEqualTo(view.safeAreaLayoutGuide)
        }

        skeletonPlaceholderView.snp.makeConstraints { make in
            make.top.equalTo(headerLabel.snp.bottom).offset(12)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(8)
            // Preference, not requirement: in a pane too short for the whole
            // placeholder it is better to let it run past the bottom edge than
            // to break a required constraint.
            make.bottom.lessThanOrEqualTo(view.safeAreaLayoutGuide).priority(.high)
        }

        scrollView.do {
            $0.hidesVisualEffectView = true
            $0.autohidesScrollers = true
            $0.backgroundColor = .clear
            $0.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }

        // A navigation list, as `SelfSizingTableView.scrollableNavigationListTableView()`
        // makes the other pages' lists: a click opens the level and leaves no
        // highlight or focus behind.
        outlineView.do {
            $0.backgroundColor = .clear
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
            $0.usesAutomaticRowHeights = true
            $0.style = .inset
            $0.refusesFirstResponder = true
            // Assign after `style`: setting `NSTableView.style` resets the
            // highlight style, so the reverse order silently does nothing.
            $0.selectionHighlightStyle = .none
            $0.intercellSpacing = .init(width: 0, height: 10)
        }

        headerLabel.do {
            $0.font = .systemFont(ofSize: 13, weight: .semibold)
            $0.textColor = .labelColor
            $0.stringValue = "Hierarchy"
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
    }

    override func setupBindings(for viewModel: InspectorHierarchyViewModel) {
        super.setupBindings(for: viewModel)

        let selectHierarchyLevel: Signal<InspectorHierarchyCellViewModel> = outlineView.rx.modelClicked().asSignal()

        let input = InspectorHierarchyViewModel.Input(
            selectHierarchyLevelClicked: selectHierarchyLevel
        )
        let output = viewModel.transform(input)

        // Bound before the visibility binding below so that when a fetch
        // finishes, the outline already holds the new levels by the time they
        // are expanded and the placeholder is taken down. `compactMap` drops
        // the `.loading` state entirely: the stale levels stay in the
        // (hidden) outline rather than being reloaded away and reloaded back.
        let roots = output.hierarchyState.compactMap { hierarchyState -> [InspectorHierarchyCellViewModel]? in
            guard case .loaded(let roots) = hierarchyState else { return nil }
            return roots
        }
        outlineView.rx.nodes(source: roots.asObservable())({ (outlineView: NSOutlineView, _: NSTableColumn?, cellViewModel: InspectorHierarchyCellViewModel) -> NSView? in
            let cellView = outlineView.box.makeView(ofClass: RuntimeObjectCellView<InspectorHierarchyCellViewModel>.self) {
                .init(contentInsets: .init(top: 0, left: 4, bottom: 0, right: 4))
            }
            cellView.bind(to: cellViewModel)
            return cellView
        })
        .disposed(by: rx.disposeBag)

        // The placeholder replaces the outline rather than overlaying it, so
        // the previous protocol's levels never show through between its bars.
        output.hierarchyState.driveOnNext { [weak self] hierarchyState in
            guard let self else { return }
            switch hierarchyState {
            case .loading:
                skeletonPlaceholderView.isPresentingPlaceholder = true
                scrollView.isHidden = true
            case .loaded:
                // A protocol's tree is a few levels deep: all of it shows.
                outlineView.expandItem(nil, expandChildren: true)
                skeletonPlaceholderView.isPresentingPlaceholder = false
                scrollView.isHidden = false
            }
        }
        .disposed(by: rx.disposeBag)
    }
}
