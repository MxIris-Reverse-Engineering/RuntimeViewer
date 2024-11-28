//
//  ViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures

class UXKitViewController<ViewModelType>: UXViewController {
    var viewModel: ViewModelType?

    init(viewModel: ViewModelType? = nil) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setupBindings(for viewModel: ViewModelType) {
        rx.disposeBag = DisposeBag()
        self.viewModel = viewModel
    }
}

class UXVisualEffectViewController<ViewModelType>: UXKitViewController<ViewModelType> {
    let contentView = NSVisualEffectView()

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            contentView
        }

        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }
}

class AppKitViewController<ViewModelType>: NSViewController {
    var viewModel: ViewModelType?

    init(viewModel: ViewModelType? = nil) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setupBindings(for viewModel: ViewModelType) {
        rx.disposeBag = DisposeBag()
        self.viewModel = viewModel
    }
}
