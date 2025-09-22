import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class SidebarRootViewController: UXEffectViewController<SidebarRootViewModel> {
    private let (scrollView, outlineView): (ScrollView, OutlineView) = OutlineView.scrollableOutlineView()

    private let filterSearchField = FilterSearchField()

    private let bottomSeparatorView = NSBox()
    
    private var dataSource: SidebarRootOutlineViewDataSource?

    override var shouldDisplayCommonLoading: Bool { true }

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
        
        dataSource = .init(viewModel: viewModel)
        
        let input = SidebarRootViewModel.Input(
            clickedNode: outlineView.rx.modelDoubleClicked().asSignal(),
            selectedNode: outlineView.rx.modelSelected().asSignal(),
            searchString: filterSearchField.rx.stringValue.asSignal()
        )

        let output = viewModel.transform(input)

        output.nodes.drive(outlineView.rx.nodes)({ (outlineView: NSOutlineView, tableColumn: NSTableColumn?, node: SidebarRootCellViewModel) -> NSView? in
            let cellView = outlineView.box.makeView(ofClass: SidebarRootTableCellView.self, owner: nil)
            cellView.bind(to: node)
            return cellView
        }, { outlineView, _ -> NSTableRowView? in
            if #available(macOS 26.0, *) {
                return outlineView.box.makeView(ofClass: SidebarRootTableRowView.self)
            } else {
                return nil
            }
        })
        .disposed(by: rx.disposeBag)

        output.nodesIndexed.asObservable().first().asObservable().subscribeOnNext { [weak self] _ in
            guard let self, let dataSource else { return }
            outlineView.rx.setDataSource(dataSource).disposed(by: rx.disposeBag)
            outlineView.autosaveExpandedItems = true
            outlineView.autosaveName = "com.JH.RuntimeViewer.SidebarRootViewController.autosaveName.\(viewModel.appServices.runtimeEngine.source.description)"
            outlineView.identifier = "com.JH.RuntimeViewer.SidebarRootViewController.identifier.\(viewModel.appServices.runtimeEngine.source.description)"
        }
        .disposed(by: rx.disposeBag)
    }
}
