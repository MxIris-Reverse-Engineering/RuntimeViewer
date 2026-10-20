import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

final class InspectorClassViewController: BaseEffectViewController<InspectorClassViewModel> {
    /// Every level is at least as tall as one with an image under its name,
    /// so the arrows to and from a level known by name only are as long as
    /// the others.
    private static let levelMinimumHeight: CGFloat = 30

    private let headerLabel = Label()

    private let (scrollView, tableView) = SelfSizingTableView.scrollableNavigationListTableView()

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

        // As tall as its levels, and no taller than the pane: past that the
        // list scrolls.
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

        tableView.do {
            // More than the other pages' 10: the rows draw the arrows between
            // the levels in it.
            $0.intercellSpacing = .init(width: 0, height: 16)
        }

        headerLabel.do {
            $0.font = .systemFont(ofSize: 13, weight: .semibold)
            $0.textColor = .labelColor
            $0.stringValue = "Hierarchy"
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
    }

    override func setupBindings(for viewModel: InspectorClassViewModel) {
        super.setupBindings(for: viewModel)

        let selectHierarchyLevel: Signal<InspectorClassHierarchyCellViewModel> = tableView.rx
            .itemClicked()
            .compactMap { [weak tableView] index -> InspectorClassHierarchyCellViewModel? in
                guard let tableView,
                      index.row >= 0,
                      index.row < tableView.numberOfRows
                else { return nil }
                return try? tableView.rx.model(at: index.row)
            }
            .asSignal(onErrorSignalWith: .empty())

        let input = InspectorClassViewModel.Input(
            selectHierarchyLevelClicked: selectHierarchyLevel
        )
        let output = viewModel.transform(input)

        // Bound before the visibility binding below so that when a fetch
        // finishes, the table already holds the new levels by the time the
        // placeholder is taken down. `compactMap` drops the `.loading` state
        // entirely: the stale levels stay in the (hidden) table rather than
        // being reloaded away and reloaded back.
        let levels = output.hierarchyState.compactMap { hierarchyState -> [InspectorClassHierarchyCellViewModel]? in
            guard case .loaded(let levels) = hierarchyState else { return nil }
            return levels
        }
        tableView.rx.items(levels.asObservable())(
            { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: InspectorClassHierarchyCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: RuntimeObjectCellView<InspectorClassHierarchyCellViewModel>.self) {
                    .init(contentInsets: .init(top: 0, left: 4, bottom: 0, right: 4), minimumHeight: InspectorClassViewController.levelMinimumHeight)
                }
                cellView.bind(to: cellViewModel)
                return cellView
            },
            { _, _, _ in
                HierarchyTimelineRowView()
            }
        )
        .disposed(by: rx.disposeBag)

        // The placeholder replaces the list rather than overlaying it, so the
        // previous object's levels never show through between its bars.
        output.hierarchyState.driveOnNext { [weak self] hierarchyState in
            guard let self else { return }
            switch hierarchyState {
            case .loading:
                skeletonPlaceholderView.isPresentingPlaceholder = true
                scrollView.isHidden = true
            case .loaded:
                skeletonPlaceholderView.isPresentingPlaceholder = false
                scrollView.isHidden = false
            }
        }
        .disposed(by: rx.disposeBag)
    }
}

extension InspectorClassViewController {
    /// A level's row in the Hierarchy list. Behind its cell it draws its part
    /// of the timeline through the middle of the level's icon: from the top
    /// edge down to an arrowhead just above the icon — the arrow from the
    /// subclass above — and from just below the icon to the bottom edge, on
    /// to the superclass below. The first level has no line in, the last no
    /// line out.
    ///
    /// Which row it is, and how many there are, is read from the table each
    /// time the row draws rather than handed over when it is made, so a row
    /// that outlives a change to the list never draws an end it no longer is.
    private final class HierarchyTimelineRowView: NSTableRowView {
        private enum Metrics {
            static let lineWidth: CGFloat = 1.5
            /// Between the icon and the line leading to it or away from it.
            static let iconClearance: CGFloat = 3
            static let arrowheadWidth: CGFloat = 7
            static let arrowheadLength: CGFloat = 5
        }

        override func layout() {
            super.layout()
            // The icon moves with the row's height, and the line with it.
            needsDisplay = true
        }

        override func drawBackground(in dirtyRect: NSRect) {
            super.drawBackground(in: dirtyRect)

            guard let tableView = superview as? NSTableView,
                  let cellView = view(atColumn: 0) as? RuntimeObjectCellView<InspectorClassHierarchyCellViewModel>
            else { return }
            let row = tableView.row(for: self)
            guard row >= 0 else { return }
            let hasLevelAbove = row > 0
            let hasLevelBelow = row < tableView.numberOfRows - 1
            guard hasLevelAbove || hasLevelBelow else { return }

            let iconFrame = convert(cellView.primaryIconFrame, from: cellView)
            // Heights are measured down from the row's top edge, whichever
            // way the view is flipped.
            let iconTopOffset = isFlipped ? iconFrame.minY - bounds.minY : bounds.maxY - iconFrame.maxY
            let iconBottomOffset = iconTopOffset + iconFrame.height

            NSColor.tertiaryLabelColor.setFill()
            if hasLevelAbove {
                let arrowTipOffset = iconTopOffset - Metrics.iconClearance
                let arrowBaseOffset = arrowTipOffset - Metrics.arrowheadLength
                fillLine(fromOffset: 0, toOffset: arrowBaseOffset, centeredAt: iconFrame.midX)
                let arrowhead = NSBezierPath()
                arrowhead.move(to: NSPoint(x: iconFrame.midX - Metrics.arrowheadWidth / 2, y: y(atOffset: arrowBaseOffset)))
                arrowhead.line(to: NSPoint(x: iconFrame.midX + Metrics.arrowheadWidth / 2, y: y(atOffset: arrowBaseOffset)))
                arrowhead.line(to: NSPoint(x: iconFrame.midX, y: y(atOffset: arrowTipOffset)))
                arrowhead.close()
                arrowhead.fill()
            }
            if hasLevelBelow {
                fillLine(fromOffset: iconBottomOffset + Metrics.iconClearance, toOffset: bounds.height, centeredAt: iconFrame.midX)
            }
        }

        /// The y coordinate `offset` points down from the row's top edge.
        private func y(atOffset offset: CGFloat) -> CGFloat {
            isFlipped ? bounds.minY + offset : bounds.maxY - offset
        }

        /// A vertical line from one height down to another, on whole device
        /// pixels so it stays sharp; nothing when there is no room for it.
        private func fillLine(fromOffset startOffset: CGFloat, toOffset endOffset: CGFloat, centeredAt centerX: CGFloat) {
            guard endOffset > startOffset else { return }
            let startY = y(atOffset: startOffset)
            let endY = y(atOffset: endOffset)
            let lineRect = NSRect(
                x: centerX - Metrics.lineWidth / 2,
                y: min(startY, endY),
                width: Metrics.lineWidth,
                height: endOffset - startOffset
            )
            backingAlignedRect(lineRect, options: .alignAllEdgesNearest).fill(using: .sourceOver)
        }
    }
}
