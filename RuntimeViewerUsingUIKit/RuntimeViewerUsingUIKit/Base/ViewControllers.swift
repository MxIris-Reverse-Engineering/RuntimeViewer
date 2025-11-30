import UIKit
import RuntimeViewerUI
import RuntimeViewerApplication

class UIKitViewController<ViewModel: ViewModelProtocol>: UIViewController {
    var viewModel: ViewModel?

    func setupBindings(for viewModel: ViewModel) {
        self.viewModel = viewModel
    }
}


