#if canImport(UIKit)

import UIKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class SidebarRootViewController: ViewController<SidebarRootViewModel> {
    let collectionView: UICollectionView = {
        var configuration = UICollectionLayoutListConfiguration(appearance: .sidebar)
        configuration.backgroundColor = UIDevice.current.userInterfaceIdiom == .phone ? .systemBackground : .secondarySystemBackground
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        return collectionView
    }()

    let searchBar = UISearchBar()

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
//            searchBar
            collectionView
        }

//        searchBar.snp.makeConstraints { make in
//            make.top.equalTo(view.safeAreaLayoutGuide)
//            make.left.right.equalTo(view.safeAreaLayoutGuide).inset(15)
//        }

        collectionView.snp.makeConstraints { make in
//            make.top.equalTo(searchBar.snp.bottom)
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.bottom.equalTo(view.safeAreaLayoutGuide)
            make.left.right.equalToSuperview()
        }

        searchBar.do {
            $0.backgroundImage = .image(withColor: .clear)
        }

        if traitCollection.userInterfaceIdiom == .phone {
            view.backgroundColor = .systemBackground
            collectionView.backgroundColor = .systemBackground
        } else {
            view.backgroundColor = .secondarySystemBackground
            collectionView.backgroundColor = .secondarySystemBackground
        }
    }

    override func setupBindings(for viewModel: SidebarRootViewModel) {
        super.setupBindings(for: viewModel)

        let input = SidebarRootViewModel.Input(clickedNode: collectionView.rx.modelSelected(SidebarRootCellViewModel.self).asSignal(), selectedNode: .never(), searchString: searchBar.rx.text.asSignalOnErrorJustComplete().filterNil())

        let output = viewModel.transform(input)

        output.nodes.drive(collectionView.rx.nodes(source:)) { (collectionView: UICollectionView, indexPath: IndexPath, viewModel: SidebarRootCellViewModel, cell: UICollectionViewListCell) in
            var content = cell.defaultContentConfiguration()
            content.attributedText = viewModel.name
            content.image = viewModel.icon
            cell.contentConfiguration = content
            cell.indentationWidth = 8
        }
        .disposed(by: rx.disposeBag)

        output.filteredNodes.drive(collectionView.rx.filteredNodes).disposed(by: rx.disposeBag)
    }
}

#endif
