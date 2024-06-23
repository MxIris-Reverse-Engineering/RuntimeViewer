#if canImport(UIKit)

import UIKit

class MainSplitViewController: UISplitViewController {
    var viewModel: MainViewModel?

    func setupBindings(for viewModel: MainViewModel) {
        self.viewModel = viewModel
    }

    init() {
        super.init(style: .doubleColumn)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .systemBackground
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

#endif
