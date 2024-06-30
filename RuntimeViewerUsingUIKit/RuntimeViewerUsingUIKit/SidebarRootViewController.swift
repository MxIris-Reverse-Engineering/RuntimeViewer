#if canImport(UIKit)

import UIKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class SidebarRootViewController: ViewController<SidebarRootViewModel> {
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: .init(appearance: .sidebar)))

    let searchBar = UISearchBar()

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            searchBar
            collectionView
        }

        searchBar.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.left.right.equalTo(view.safeAreaLayoutGuide).inset(15)
        }

        collectionView.snp.makeConstraints { make in
            make.top.equalTo(searchBar.snp.bottom)
            make.bottom.equalTo(view.safeAreaLayoutGuide)
            make.left.right.equalToSuperview()
        }

        searchBar.do {
            $0.backgroundImage = .image(withColor: .clear)
        }

        view.backgroundColor = .secondarySystemBackground
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
