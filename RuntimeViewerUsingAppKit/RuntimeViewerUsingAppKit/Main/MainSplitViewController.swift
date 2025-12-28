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

    func setupSplitViewItems() {
        splitViewItems[safe: 0]?.do {
            $0.minimumThickness = 300
            $0.maximumThickness = NSSplitViewItem.unspecifiedDimension
            $0.holdingPriority = .init(261)
        }

        splitViewItems[safe: 1]?.do {
            $0.minimumThickness = 300
            $0.maximumThickness = NSSplitViewItem.unspecifiedDimension
            $0.holdingPriority = .init(250)
        }

        splitViewItems[safe: 2]?.do {
            $0.minimumThickness = 260
            $0.maximumThickness = NSSplitViewItem.unspecifiedDimension
            $0.holdingPriority = .init(261)
        }

        splitView.autosaveName = nil
        splitView.autosaveName = "com.JH.RuntimeViewer.\(Self.self).autosaveName"
    }

    func setupBindings(for viewModel: MainViewModel) {
        self.viewModel = viewModel
    }
}
