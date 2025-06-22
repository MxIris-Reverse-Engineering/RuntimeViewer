#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication

class LoadFrameworksViewModel: ViewModel<MainRoute> {}

class LoadFrameworksViewController: AppKitViewController<LoadFrameworksViewModel> {
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
    }
}

#endif
