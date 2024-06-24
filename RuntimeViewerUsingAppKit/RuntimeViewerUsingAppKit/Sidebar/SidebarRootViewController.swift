//
//  SidebarViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class SidebarRootViewController: ViewController<SidebarRootViewModel> {
    let (scrollView, outlineView): (ScrollView, OutlineView) = OutlineView.scrollableOutlineView()

    let visualEffectView = NSVisualEffectView()

    let filterSearchField = FilterSearchField()

    let bottomSeparatorView = NSBox()

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            visualEffectView.hierarchy {
                scrollView
                bottomSeparatorView
                filterSearchField
            }
        }

        visualEffectView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        scrollView.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
            make.bottom.equalTo(bottomSeparatorView.snp.top)
        }

        bottomSeparatorView.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
            make.bottom.equalTo(filterSearchField.snp.top).offset(-5)
            make.height.equalTo(1)
        }

        filterSearchField.snp.makeConstraints { make in
            make.left.right.bottom.equalToSuperview().inset(5)
        }

        bottomSeparatorView.do {
            $0.boxType = .separator
        }

        outlineView.do {
            $0.addTableColumn(NSTableColumn(identifier: .init("Default")))
            $0.headerView = nil
            $0.autosaveName = "com.JH.RuntimeViewer.SidebarRootViewController.autosaveName"
            $0.autosaveExpandedItems = true
            $0.identifier = .init("com.JH.RuntimeViewer.SidebarRootViewController.identifier")
        }
    }

    override func setupBindings(for viewModel: SidebarRootViewModel) {
        super.setupBindings(for: viewModel)

        let input = SidebarRootViewModel.Input(
            clickedNode: outlineView.rx.modelDoubleClicked().asSignal(),
            selectedNode: outlineView.rx.modelSelected().asSignal(),
            searchString: filterSearchField.rx.stringValue.asSignal()
        )

        let output = viewModel.transform(input)

        output.rootNode.drive(outlineView.rx.rootNode) { (outlineView: NSOutlineView, tableColumn: NSTableColumn?, node: SidebarRootCellViewModel) -> NSView? in
            let cellView = outlineView.box.makeView(ofClass: SidebarRootTableCellView.self, owner: nil)
            cellView.bind(to: node)
            return cellView
        }
        .disposed(by: rx.disposeBag)
        outlineView.rx.setDataSource(viewModel).disposed(by: rx.disposeBag)
    }
}
