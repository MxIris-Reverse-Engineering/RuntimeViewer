//
//  SidebarImageViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures

class SidebarImageViewController: ViewController<SidebarImageViewModel> {
    let visualEffectView = NSVisualEffectView()

    let (scrollView, tableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            visualEffectView.hierarchy {
                scrollView
            }
        }

        visualEffectView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    override func setupBindings(for viewModel: SidebarImageViewModel) {
        super.setupBindings(for: viewModel)

        let input = SidebarImageViewModel.Input(clickedRuntimeObject: tableView.rx.modelSelected().asSignal())
        let output = viewModel.transform(input)
        output.runtimeObjects.drive(tableView.rx.items) { tableView, _, _, item in
            let cellView = tableView.box.makeView(ofClass: SidebarImageCellView.self, owner: nil)
            cellView.bind(to: item)
            return cellView
        }
        .disposed(by: rx.disposeBag)
    }
}

class SidebarImageCellView: ImageTextTableCellView {
    func bind(to viewModel: SidebarImageCellViewModel) {
        rx.disposeBag = DisposeBag()
        viewModel.$icon.asDriver().drive(_imageView.rx.image).disposed(by: rx.disposeBag)
        viewModel.$name.asDriver().drive(_textField.rx.attributedStringValue).disposed(by: rx.disposeBag)
    }
}
