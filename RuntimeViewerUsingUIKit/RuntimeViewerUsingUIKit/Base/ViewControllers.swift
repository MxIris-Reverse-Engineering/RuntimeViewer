import UIKit
import RuntimeViewerUI

class UIKitViewController<ViewModelType>: UIViewController {
    var viewModel: ViewModelType?

    func setupBindings(for viewModel: ViewModelType) {
        self.viewModel = viewModel
    }
}


