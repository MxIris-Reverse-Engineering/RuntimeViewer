#if canImport(UIKit)

import UIKit

class MainSplitViewController: UISplitViewController {
    var viewModel: MainViewModel?

    func setupBindings(for viewModel: MainViewModel) {
        self.viewModel = viewModel
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .systemBackground

    }
}

#endif
