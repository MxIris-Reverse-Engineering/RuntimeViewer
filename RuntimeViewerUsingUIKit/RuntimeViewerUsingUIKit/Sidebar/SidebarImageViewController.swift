#if canImport(UIKit)

import UIKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class SidebarImageViewController: UIKitViewController<SidebarImageViewModel> {
    @MagicViewLoading
    var imageTabBarController = UITabBarController()

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

        if #available(iOS 18.0, *) {
            imageTabBarController.isTabBarHidden = true
        } else {
            imageTabBarController.tabBar.isHidden = true
        }

        imageTabBarController.view.backgroundColor = .clear

        imageTabBarController.viewControllers = [
            UIViewController(view: imageNotLoadedView),
            UIViewController(view: imageLoadingView),
            UIViewController(view: imageLoadedView),
            UIViewController(view: imageLoadErrorView),
        ]

        if #unavailable(iOS 26.0) {
            if traitCollection.userInterfaceIdiom == .phone {
                view.backgroundColor = .systemBackground
            } else {
                view.backgroundColor = .secondarySystemBackground
            }
        }
    }

    override func setupBindings(for viewModel: SidebarImageViewModel) {
        super.setupBindings(for: viewModel)
        let input = SidebarImageViewModel.Input(
            runtimeObjectClicked: imageLoadedView.listView.rx.modelSelected(SidebarImageCellViewModel.self).asSignal(),
            loadImageClicked: Signal.of(
                imageNotLoadedView.loadImageButton.rx.tap.asSignal(),
                imageLoadErrorView.loadImageButton.rx.tap.asSignal()
            ).merge(),
            searchString: imageLoadedView.searchBar.rx.text.asSignalOnErrorJustComplete().filterNil()
        )

        let output = viewModel.transform(input)
        let listCellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, SidebarImageCellViewModel> { cell, indexPath, viewModel in
            var content = cell.defaultContentConfiguration()
            content.textProperties.allowsDefaultTighteningForTruncation = false
            content.attributedText = viewModel.name
            content.image = viewModel.icon

            cell.contentConfiguration = content
        }

        output.runtimeObjects.drive(imageLoadedView.listView.rx.items) { collectionView, index, viewModel -> UICollectionViewCell in
            collectionView.dequeueConfiguredReusableCell(using: listCellRegistration, for: IndexPath(item: index, section: 0), item: viewModel)
        }
        .disposed(by: rx.disposeBag)

        output.errorText.drive(imageLoadErrorView.titleLabel.rx.text).disposed(by: rx.disposeBag)

        output.notLoadedText.drive(imageNotLoadedView.titleLabel.rx.text).disposed(by: rx.disposeBag)

        output.emptyText.drive(imageLoadedView.emptyLabel.rx.text).disposed(by: rx.disposeBag)

        output.isEmpty.drive(imageLoadedView.searchBar.rx.isHidden).disposed(by: rx.disposeBag)

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
        case .unknown:
            4
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
        #if os(tvOS)
        let searchBar = UISearchBar.make()
        #else
        let searchBar = UISearchBar()
        #endif

        let listView: UICollectionView = {
            #if os(tvOS)
            var configuration = UICollectionLayoutListConfiguration(appearance: .grouped)
            #else
            var configuration = UICollectionLayoutListConfiguration(appearance: .sidebar)
            #endif
            if #available(iOS 26.0, *) {
                configuration.backgroundColor = .clear
            } else {
                configuration.backgroundColor = UIDevice.current.userInterfaceIdiom == .phone ? .systemBackground : .secondarySystemBackground
            }
            let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
            return collectionView
        }()

        let emptyLabel = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)

            hierarchy {
                searchBar
                listView
                emptyLabel
            }

            searchBar.snp.makeConstraints { make in
                make.top.equalToSuperview()
                make.left.right.equalToSuperview().inset(15)
            }

            listView.snp.makeConstraints { make in
                make.top.equalTo(searchBar.snp.bottom)
                make.bottom.left.right.equalToSuperview().inset(15)
            }

            emptyLabel.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.left.right.equalToSuperview().inset(15)
            }

            emptyLabel.do {
                $0.textAlignment = .center
                $0.numberOfLines = 0
            }

            searchBar.do {
                $0.backgroundImage = .image(withColor: .clear)
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
                $0.numberOfLines = 0
            }

            loadImageButton.do {
                $0.configuration = .tinted()
                $0.setTitle("Load now", for: .normal)
            }
        }
    }
}

#endif
