import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class SidebarRootViewController<ViewModel: SidebarRootViewModel>: UXKitViewController<ViewModel> {
    
    var isReorderable: Bool { false }
    
    let (scrollView, outlineView): (ScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableOutlineView()

    private let filterSearchField = FilterSearchField()

    private let bottomSeparatorView = NSBox()

    private var dataSource: OutlineViewDataSource?

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
            make.bottom.equalTo(filterSearchField.snp.top).offset(-8)
            make.height.equalTo(1)
        }

        filterSearchField.snp.makeConstraints { make in
            make.left.right.equalToSuperview().inset(10)
            if #available(macOS 26.0, *) {
                make.bottom.equalTo(view.layoutGuide(for: .safeArea())).inset(8)
            } else {
                make.bottom.equalToSuperview().inset(8)
            }
        }

        bottomSeparatorView.do {
            $0.boxType = .separator
        }

        filterSearchField.do {
            if #available(macOS 26.0, *) {
                $0.controlSize = .extraLarge
                $0.font = .systemFont(ofSize: NSFont.systemFontSize)
                $0.cell?.font = .systemFont(ofSize: NSFont.systemFontSize)
                ($0.cell as? NSTextFieldCell)?.placeholderString = nil
            } else {
                $0.controlSize = .large
            }
        }

        scrollView.do {
            $0.isHiddenVisualEffectView = true
        }

        outlineView.do {
            $0.addTableColumn(NSTableColumn(identifier: .init("Default")))
            $0.headerView = nil
            $0.autoresizesOutlineColumn = false
        }
    }

    override func setupBindings(for viewModel: ViewModel) {
        super.setupBindings(for: viewModel)

        dataSource = .init(viewModel: viewModel)

        let input = ViewModel.Input(
            clickedNode: outlineView.rx.modelDoubleClicked().asSignal(),
            selectedNode: outlineView.rx.modelSelected().asSignal(),
            searchString: filterSearchField.rx.stringValue.asSignal()
        )

        let output = viewModel.transform(input)

        output.nodes.drive(isReorderable ? outlineView.rx.reorderableNodes : outlineView.rx.nodes)({ (outlineView: NSOutlineView, tableColumn: NSTableColumn?, node: SidebarRootCellViewModel) -> NSView? in
            let cellView = outlineView.box.makeView(ofClass: SidebarRootTableCellView.self)
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

        output.didBeginFiltering.emitOnNext { [weak self] in
            guard let self else { return }
            outlineView.beginFiltering()
        }
        .disposed(by: rx.disposeBag)

        output.didChangeFiltering.emitOnNext { [weak self] in
            guard let self else { return }
            outlineView.expandItem(nil, expandChildren: true)
        }
        .disposed(by: rx.disposeBag)

        output.didEndFiltering.emitOnNext { [weak self] in
            guard let self else { return }
            outlineView.endFiltering()
        }
        .disposed(by: rx.disposeBag)

        output.nodesIndexed
            .delay(.milliseconds(100))
            .asObservable()
            .first()
            .asObservable()
            .subscribeOnNext { [weak self] _ in
                guard let self, let dataSource else { return }
                outlineView.rx.setDataSource(dataSource).disposed(by: rx.disposeBag)
                outlineView.autosaveExpandedItems = true
                outlineView.identifier = "com.JH.RuntimeViewer.\(Self.self).identifier.\(viewModel.documentState.runtimeEngine.source.description)"
                outlineView.autosaveName = "com.JH.RuntimeViewer.\(Self.self).autosaveName.\(viewModel.documentState.runtimeEngine.source.description)"
            }
            .disposed(by: rx.disposeBag)
    }
}

extension SidebarRootViewController {
    private final class OutlineViewDataSource: NSObject, NSOutlineViewDataSource {
        private unowned let viewModel: ViewModel

        init(viewModel: ViewModel) {
            self.viewModel = viewModel
            super.init()
        }

        func outlineView(_ outlineView: NSOutlineView, itemForPersistentObject object: Any) -> Any? {
            guard !viewModel.isFiltering else { return nil }
            guard let path = object as? String else {
                return nil
            }
            let item = viewModel.allNodes[path]
            return item
        }

        func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any? {
            guard !viewModel.isFiltering else { return nil }
            guard let item = item as? SidebarRootCellViewModel else { return nil }
            let returnObject = item.node.parent != nil ? item.node.absolutePath : item.node.name
            return returnObject
        }
    }
}
