import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import Dependencies

class MainSplitViewController: NSSplitViewController {
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
            $0.minimumThickness = 250
            $0.maximumThickness = 400
        }

        splitViewItems[1].do {
            $0.minimumThickness = 600
            if #available(macOS 26.0, *) {
                $0.automaticallyAdjustsSafeAreaInsets = true
            }
        }

        splitViewItems[2].do {
            $0.minimumThickness = 200
        }

        if appDefaults.isInitialSetupSplitView {
            splitView.setPosition(250, ofDividerAt: 0)
            appDefaults.isInitialSetupSplitView = false
        }

        splitView.identifier = "com.JH.RuntimeViewer.\(Self.self).identifier\(".\(viewModel?.appServices.runtimeEngine.source.description ?? "")")"
        splitView.autosaveName = "com.JH.RuntimeViewer.\(Self.self).autosaveName\(".\(viewModel?.appServices.runtimeEngine.source.description ?? "")")"
    }
}
