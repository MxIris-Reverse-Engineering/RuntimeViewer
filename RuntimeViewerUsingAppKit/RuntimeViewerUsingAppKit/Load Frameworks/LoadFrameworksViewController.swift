#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication

final class LoadFrameworksViewModel: ViewModel<MainRoute> {}

final class LoadFrameworksViewController: UXKitViewController<LoadFrameworksViewModel> {
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
    }
}

#endif
