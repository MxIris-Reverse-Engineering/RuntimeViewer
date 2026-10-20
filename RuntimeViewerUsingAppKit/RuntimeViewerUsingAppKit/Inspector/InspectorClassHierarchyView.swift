import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

final class InspectorClassHierarchyView: InspectorDisclosureView<InspectorClassHierarchyContentView> {
    init() {
        super.init(contentView: .init())
        title = "Hierarchy"
    }

    /// The list of levels, for the view controller to bind its rows to.
    var tableView: NSTableView {
        contentView.tableView
    }

    func apply(_ hierarchyState: InspectorClassViewModel.HierarchyState) {
        contentView.apply(hierarchyState)
    }
}

/// Content area of the Hierarchy disclosure: the list of levels, one
/// `RuntimeObjectCellView` row each, and the loading placeholder that stands
/// in for it, never both at once.
///
/// The list runs edge to edge, as the Relationships page's does: its inset
/// style leaves the margin, so the icons of the two pages line up. The
/// placeholder takes the Relationships page's place too, 8 points in and 12
/// below the title. The list is hidden while the placeholder shows, rows and
/// all, and keeps the area's height for that time; a placeholder taller than
/// the last list runs on below it rather than resize the page.
final class InspectorClassHierarchyContentView: XiblessView {
    private let scrollView: SelfSizingScrollView

    let tableView: SelfSizingTableView

    private let skeletonPlaceholderView = SkeletonPlaceholderView.runtimeObjectList()

    override init(frame frameRect: CGRect) {
        (scrollView, tableView) = SelfSizingTableView.scrollableNavigationListTableView()
        super.init(frame: frameRect)

        hierarchy {
            scrollView
            skeletonPlaceholderView
        }

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        skeletonPlaceholderView.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(4)
            make.leading.trailing.equalToSuperview().inset(8)
        }

        tableView.do {
            // More than the Relationships page's 10: the rows draw the arrows
            // between the levels in it.
            $0.intercellSpacing = .init(width: 0, height: 16)
        }
    }

    func apply(_ hierarchyState: InspectorClassViewModel.HierarchyState) {
        switch hierarchyState {
        case .loading:
            skeletonPlaceholderView.isPresentingPlaceholder = true
            scrollView.isHidden = true
        case .loaded:
            skeletonPlaceholderView.isPresentingPlaceholder = false
            scrollView.isHidden = false
        }
    }
}
