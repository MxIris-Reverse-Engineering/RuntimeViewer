import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

final class InspectorClassHierarchyView: InspectorDisclosureView<InspectorClassHierarchyContentView> {
    init() {
        super.init(contentView: .init())
        title = "Hierarchy"
    }

    func apply(_ hierarchyState: InspectorClassViewModel.HierarchyState) {
        contentView.apply(hierarchyState)
    }
}

/// Content area of the Hierarchy disclosure: the hierarchy text and the
/// loading placeholder that stands in for it, never both at once.
///
/// The two live in a stack view rather than overlapping, because a hidden
/// `NSView` still contributes its size to Auto Layout while a hidden
/// *arranged* subview is detached from the layout entirely — which is what
/// lets the disclosure area size itself to whichever of the two is showing.
final class InspectorClassHierarchyContentView: XiblessView {
    private let hierarchyLabel = Label()

    private let skeletonPlaceholderView = SkeletonPlaceholderView.classHierarchy()

    private lazy var contentStackView = VStackView(alignment: .leading, spacing: 0) {
        hierarchyLabel
        skeletonPlaceholderView
    }

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)

        hierarchy {
            contentStackView
        }

        contentStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        hierarchyLabel.do {
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            $0.textColor = .controlTextColor
            $0.font = .systemFont(ofSize: 12, weight: .regular)
        }
    }

    func apply(_ hierarchyState: InspectorClassViewModel.HierarchyState) {
        switch hierarchyState {
        case .loading:
            // Clearing the text matters as much as hiding the label: the label
            // is reused across objects, so leaving the previous object's
            // hierarchy in place would flash it back on screen for a frame
            // when the placeholder goes away.
            hierarchyLabel.stringValue = ""
            hierarchyLabel.isHidden = true
            skeletonPlaceholderView.isPresentingPlaceholder = true
        case .loaded(let hierarchy):
            hierarchyLabel.stringValue = hierarchy
            hierarchyLabel.isHidden = false
            skeletonPlaceholderView.isPresentingPlaceholder = false
        }
    }
}
