import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class InspectorClassHierarchyView: InspectorDisclosureView<Label> {
    var hierarchyString: String = "" {
        didSet {
            contentView.stringValue = hierarchyString
        }
    }

    init() {
        super.init(contentView: .init())
        title = "Hierarchy"
        contentView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentView.textColor = .controlTextColor
        contentView.font = .systemFont(ofSize: 12, weight: .regular)
    }
}
