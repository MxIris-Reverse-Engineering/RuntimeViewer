import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import Dependencies

final class MainSplitViewController: NSSplitViewController {
    var viewModel: MainViewModel?

    @Dependency(\.appDefaults)
    private var appDefaults

    override func viewDidLoad() {
        super.viewDidLoad()

        if appDefaults.isInitialSetupSplitView {
            view.frame = .init(x: 0, y: 0, width: 1280, height: 800)
        }
    }

    func setupSplitViewItems() {
        splitViewItems[0].do {
            $0.minimumThickness = 300
            $0.maximumThickness = NSSplitViewItem.unspecifiedDimension
            $0.holdingPriority = .init(261)
        }

        splitViewItems[1].do {
            $0.minimumThickness = 300
            $0.maximumThickness = NSSplitViewItem.unspecifiedDimension
            $0.holdingPriority = .init(250)
        }

        splitViewItems[2].do {
            $0.minimumThickness = 260
            $0.maximumThickness = NSSplitViewItem.unspecifiedDimension
            $0.holdingPriority = .init(261)
        }

        if appDefaults.isInitialSetupSplitView {
            splitView.setPosition(300, ofDividerAt: 0)
            appDefaults.isInitialSetupSplitView = false
        }

        splitView.identifier = .init("MainSplitViewController-Identifier")
        splitView.autosaveName = .init("MainSplitViewController-AutosaveName")
    }
}
