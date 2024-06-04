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
    }

    override func setupBindings(for viewModel: SidebarRootViewModel) {
        super.setupBindings(for: viewModel)

        let input = SidebarRootViewModel.Input(
            clickedNode: outlineView.rx.doubleClickedItem().asSignal(),
            selectedNode: outlineView.rx.selectedItem().asSignal()
        )

        let output = viewModel.transform(input)

        output.rootNode.drive(outlineView.rx.rootNode) { (outlineView: NSOutlineView, tableColumn: NSTableColumn?, node: RuntimeNamedNode) -> NSView? in

            return nil
        }
        .disposed(by: rx.disposeBag)
    }
}
