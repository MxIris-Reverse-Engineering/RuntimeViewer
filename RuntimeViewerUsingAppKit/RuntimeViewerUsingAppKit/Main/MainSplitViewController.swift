import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import Dependencies

final class MainSplitViewController: NSSplitViewController {
    private var viewModel: MainViewModel?

    @Dependency(\.appDefaults)
    private var appDefaults

    override var splitViewItems: [NSSplitViewItem] {
        didSet {}
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.identifier = .makeIdentifier(of: Self.self)
    }

    private static let sidebarMinimumWidth: CGFloat = 300

    private static let contentMinimumWidth: CGFloat = 300

    private static let inspectorMinimumWidth: CGFloat = 260

    func setupSplitViewItems() {
        splitViewItems[safe: 0]?.do {
            $0.minimumThickness = Self.sidebarMinimumWidth
            $0.maximumThickness = NSSplitViewItem.unspecifiedDimension
            $0.holdingPriority = .init(261)
        }

        splitViewItems[safe: 1]?.do {
            $0.minimumThickness = Self.contentMinimumWidth
            $0.maximumThickness = NSSplitViewItem.unspecifiedDimension
            $0.holdingPriority = .init(250)
        }

        splitViewItems[safe: 2]?.do {
            $0.minimumThickness = Self.inspectorMinimumWidth
            $0.maximumThickness = NSSplitViewItem.unspecifiedDimension
            $0.holdingPriority = .init(261)
        }

        let autosaveName = "com.JH.RuntimeViewer.\(Self.self).autosaveName"

        let fullAutosaveName = "NSSplitView Subview Frames \(autosaveName)"

        let isInitialSetupAutosaveName = UserDefaults.standard.array(forKey: fullAutosaveName) == nil

        splitView.autosaveName = nil
        splitView.autosaveName = autosaveName

        DispatchQueue.main.async { [self] in
            if isInitialSetupAutosaveName {
                splitView.setPosition(Self.sidebarMinimumWidth, ofDividerAt: 0)
                splitView.setPosition(view.bounds.width - Self.inspectorMinimumWidth, ofDividerAt: 1)
            }
        }
    }

    func setupBindings(for viewModel: MainViewModel) {
        self.viewModel = viewModel
    }
}
