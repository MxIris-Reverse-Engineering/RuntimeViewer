//
//  SidebarViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures

class SidebarRootViewController: ViewController<SidebarRootViewModel> {
    let (scrollView, outlineView): (ScrollView, OutlineView) = OutlineView.scrollableOutlineView()

    override func viewDidLoad() {
        super.viewDidLoad()
        hierarchy {
            scrollView
        }

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        outlineView.do {
            $0.addTableColumn(NSTableColumn(identifier: .init("Default")))
            $0.headerView = nil
        }
    }

    override func setupBindings(for viewModel: SidebarRootViewModel) {
        super.setupBindings(for: viewModel)

        let input = SidebarRootViewModel.Input(
            clickedNode: outlineView.rx.doubleClickedItem().asSignal(),
            selectedNode: outlineView.rx.selectedItem().asSignal()
        )

        let output = viewModel.transform(input)

        output.rootNode.drive(outlineView.rx.rootNode) { (outlineView: NSOutlineView, tableColumn: NSTableColumn?, node: SidebarRootCellViewModel) -> NSView? in
            let cellView = outlineView.box.makeView(ofClass: SidebarRootTableCellView.self, owner: nil)
            cellView.bind(to: node)
            return cellView
        }
        .disposed(by: rx.disposeBag)
    }
}

class SidebarRootTableCellView: ImageTextTableCellView {
    
    func bind(to viewModel: SidebarRootCellViewModel) {
        rx.disposeBag = DisposeBag()
        viewModel.$icon.asDriver().drive(_imageView.rx.image).disposed(by: rx.disposeBag)
        viewModel.$name.asDriver().drive(_textField.rx.attributedStringValue).disposed(by: rx.disposeBag)
    }
}
