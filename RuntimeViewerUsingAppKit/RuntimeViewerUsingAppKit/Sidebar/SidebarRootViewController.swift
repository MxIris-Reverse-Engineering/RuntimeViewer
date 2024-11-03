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

class SidebarRootViewController: UXVisualEffectViewController<SidebarRootViewModel> {
    let (scrollView, outlineView): (ScrollView, OutlineView) = OutlineView.scrollableOutlineView()

    let filterSearchField = FilterSearchField()

    let bottomSeparatorView = NSBox()

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            scrollView
            bottomSeparatorView
            filterSearchField
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

        output.nodes.drive(outlineView.rx.nodes) { (outlineView: NSOutlineView, tableColumn: NSTableColumn?, node: SidebarRootCellViewModel) -> NSView? in
            let cellView = outlineView.box.makeView(ofClass: SidebarRootTableCellView.self, owner: nil)
            cellView.bind(to: node)
            return cellView
        }
        .disposed(by: rx.disposeBag)

//        output.nodes.mapToVoid().drive(with: self) { $0.outlineView.setNeedsReloadAutosaveExpandedItems() }.disposed(by: rx.disposeBag)
        
        

        outlineView.rx.setDataSource(viewModel).disposed(by: rx.disposeBag)
        outlineView.autosaveExpandedItems = true
        outlineView.autosaveName = "com.JH.RuntimeViewer.SidebarRootViewController.autosaveName.\(viewModel.appServices.runtimeListings.source.description)"
        outlineView.identifier = "com.JH.RuntimeViewer.SidebarRootViewController.identifier.\(viewModel.appServices.runtimeListings.source.description)"
        
    }
}

extension NSOutlineView {
    func setNeedsReloadAutosaveExpandedItems() {
        autosaveExpandedItems = !autosaveExpandedItems
        autosaveExpandedItems = !autosaveExpandedItems
    }
}
