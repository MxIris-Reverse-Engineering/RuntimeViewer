#if canImport(UIKit)

import UIKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class SidebarRootViewController: ViewController<SidebarRootViewModel> {
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: .init(appearance: .sidebar)))

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            collectionView
        }

        collectionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    override func setupBindings(for viewModel: SidebarRootViewModel) {
        super.setupBindings(for: viewModel)
        let headerCellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, SidebarRootCellViewModel> { cell, indexPath, viewModel in
            var content = cell.defaultContentConfiguration()
            content.attributedText = viewModel.name
            content.image = viewModel.icon
            cell.contentConfiguration = content
            cell.indentationWidth = 8
            cell.accessories = [.outlineDisclosure(options: .init(style: .header))]
        }
        let leafCellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, SidebarRootCellViewModel> { cell, indexPath, viewModel in
            var content = cell.defaultContentConfiguration()
            content.attributedText = viewModel.name
            content.image = viewModel.icon
            cell.contentConfiguration = content
            cell.indentationWidth = 8
        }
        let input = SidebarRootViewModel.Input(clickedNode: collectionView.rx.modelSelected(SidebarRootCellViewModel.self).asSignal(), selectedNode: .never(), searchString: .never())

        let output = viewModel.transform(input)

        output.rootNode.drive(collectionView.rx.rootNode(source:)) { (collectionView: UICollectionView, indexPath: IndexPath, viewModel: SidebarRootCellViewModel) -> UICollectionViewCell? in
            if viewModel.isExpandable {
                return collectionView.dequeueConfiguredReusableCell(using: headerCellRegistration, for: indexPath, item: viewModel)
            } else {
                return collectionView.dequeueConfiguredReusableCell(using: leafCellRegistration, for: indexPath, item: viewModel)
            }
        }
        .disposed(by: rx.disposeBag)
    }
}

#endif
