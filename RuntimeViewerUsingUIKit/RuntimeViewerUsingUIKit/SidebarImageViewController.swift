#if canImport(UIKit)

import UIKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class XiblessView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class SidebarImageViewController: ViewController<SidebarImageViewModel> {
    let imageTabBarController = UITabBarController()

    let imageNotLoadedView = ImageLoadableView()

    let imageLoadingView = ImageLoadingView()

    let imageLoadedView = ImageLoadedView()

    let imageLoadErrorView = ImageLoadableView()

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            imageTabBarController
        }

        imageTabBarController.view.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }

        imageTabBarController.tabBar.isHidden = true

        imageTabBarController.viewControllers = [
            UIViewController(view: imageNotLoadedView),
            UIViewController(view: imageLoadingView),
            UIViewController(view: imageLoadedView),
            UIViewController(view: imageLoadErrorView),
        ]
        imageLoadedView.tableView.register(UITableViewCell.self, forCellReuseIdentifier: .init(describing: UITableViewCell.self))
        view.backgroundColor = .systemBackground
    }

    override func setupBindings(for viewModel: SidebarImageViewModel) {
        super.setupBindings(for: viewModel)
        let input = SidebarImageViewModel.Input(
            runtimeObjectClicked: imageLoadedView.tableView.rx.modelSelected(SidebarImageCellViewModel.self).asSignal(),
            loadImageClicked: Signal.of(
                imageNotLoadedView.loadImageButton.rx.tap.asSignal(),
                imageLoadErrorView.loadImageButton.rx.tap.asSignal()
            ).merge(),
            searchString: imageLoadedView.searchBar.rx.text.asSignalOnErrorJustComplete().filterNil()
        )

        let output = viewModel.transform(input)

        output.runtimeObjects.drive(imageLoadedView.tableView.rx.items(cellIdentifier: .init(describing: UITableViewCell.self), cellType: UITableViewCell.self)) { _, viewModel, cell in
            var contentConfiguration = cell.defaultContentConfiguration()
            contentConfiguration.image = viewModel.icon
            contentConfiguration.attributedText = viewModel.name
            cell.contentConfiguration = contentConfiguration
        }
        .disposed(by: rx.disposeBag)

        output.errorText.drive(imageLoadErrorView.titleLabel.rx.text).disposed(by: rx.disposeBag)

        output.notLoadedText.drive(imageNotLoadedView.titleLabel.rx.text).disposed(by: rx.disposeBag)

        output.emptyText.drive(imageLoadedView.emptyLabel.rx.text).disposed(by: rx.disposeBag)

        output.isEmpty.not().drive(imageLoadedView.emptyLabel.rx.isHidden).disposed(by: rx.disposeBag)

        output.loadState.map { $0.index }.drive(imageTabBarController.rx.selectedIndex).disposed(by: rx.disposeBag)
    }
}

extension RuntimeImageLoadState {
    var index: Int {
        switch self {
        case .notLoaded:
            0
        case .loading:
            1
        case .loaded:
            2
        case .loadError:
            3
        }
    }
}

extension SidebarImageViewController {
    class ImageLoadingView: XiblessView {
        let loadingIndicator: MaterialLoadingIndicator = .init(radius: 25, color: .tintColor)

        override init(frame frameRect: CGRect) {
            super.init(frame: frameRect)

            hierarchy {
                loadingIndicator
            }

            loadingIndicator.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.size.equalTo(50)
            }

            loadingIndicator.startAnimating()
        }
    }

    class ImageLoadedView: XiblessView {
        let searchBar = UISearchBar()

        let tableView = UITableView(frame: .zero, style: .insetGrouped)

        let emptyLabel = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)

            hierarchy {
                searchBar
                tableView
                emptyLabel
            }

            searchBar.snp.makeConstraints { make in
                make.top.left.right.equalToSuperview().inset(15)
            }

            tableView.snp.makeConstraints { make in
                make.top.equalTo(searchBar.snp.bottom)
                make.bottom.left.right.equalToSuperview().inset(15)
            }

            emptyLabel.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.left.right.equalToSuperview().inset(15)
            }

            emptyLabel.do {
                $0.textAlignment = .center
            }
            
            searchBar.do {
                $0.backgroundImage = nil
            }
        }
    }

    class ImageLoadableView: XiblessView {
        let titleLabel = UILabel()

        let loadImageButton = UIButton(type: .system)

        lazy var contentView = VStackView(alignment: .vStackCenter, spacing: 10) {
            titleLabel
            loadImageButton
        }

        override init(frame frameRect: CGRect) {
            super.init(frame: frameRect)

            hierarchy {
                contentView
            }

            contentView.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.width.equalTo(200)
            }

            titleLabel.do {
                $0.textAlignment = .center
            }

            loadImageButton.do {
                $0.setTitle("Load now", for: .normal)
            }
        }
    }
}

extension UIViewController {
    convenience init(view: UIView) {
        self.init()
        self.view = view
    }
}

#endif
