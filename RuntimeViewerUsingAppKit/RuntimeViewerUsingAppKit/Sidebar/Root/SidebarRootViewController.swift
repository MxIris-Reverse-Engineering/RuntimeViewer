import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class SidebarRootViewController<ViewModel: SidebarRootViewModel>: UXKitViewController<ViewModel> {
    var isReorderable: Bool {
        false
    }

    let (scrollView, outlineView): (ScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()

    private let filterSearchField = FilterSearchField()

    private let bottomSeparatorView = NSBox()

    private var delegate: OutlineViewDelegate?

    override var shouldDisplayCommonLoading: Bool {
        true
    }

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
                $0.textFieldCell?.placeholderString = nil
            } else {
                $0.controlSize = .large
            }
        }

        scrollView.do {
            $0.isHiddenVisualEffectView = true
        }
    }

    override func setupBindings(for viewModel: ViewModel) {
        super.setupBindings(for: viewModel)

        delegate = .init(viewModel: viewModel)

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
            outlineView.reloadData()
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
                guard let self, let delegate else { return }

                outlineView.rx.setDelegate(delegate).disposed(by: rx.disposeBag)
                outlineView.identifier = "com.JH.RuntimeViewer.\(Self.self).identifier.\(viewModel.documentState.runtimeEngine.source.description)"

                // Manual expansion autosave: NSOutlineView's built-in
                // `autosaveExpandedItems` only attempts the first restore at the
                // intersection of "dataSource installed", "numberOfRows > 0" and
                // "autosaveName set". With async data + post-index dataSource
                // installation, that window is unreliable. StatefulOutlineView
                // persists under the same UserDefaults key so existing data
                // stays compatible.
                outlineView.persistentObjectForExpansion = { [weak viewModel] item in
                    guard let viewModel, !viewModel.isFiltering else { return nil }
                    guard let cellViewModel = item as? SidebarRootCellViewModel else { return nil }
                    return cellViewModel.node.parent != nil ? cellViewModel.node.absolutePath : cellViewModel.node.name
                }
                outlineView.itemForExpansionPersistentObject = { [weak viewModel] persistentObject in
                    guard let viewModel, !viewModel.isFiltering else { return nil }
                    return viewModel.allNodes[persistentObject]
                }
                outlineView.expansionAutosaveName = "com.JH.RuntimeViewer.\(Self.self).autosaveName.\(viewModel.documentState.runtimeEngine.source.description)"
                outlineView.restoreExpansionFromAutosave()
            }
            .disposed(by: rx.disposeBag)
        
        output.expandItem
            .emitOnNextMainActor { [weak self] viewModel in
                guard let self else { return }
                outlineView.expandItem(viewModel, expandChildren: true)
            }
            .disposed(by: rx.disposeBag)
    }
}

extension SidebarRootViewController {
    private final class OutlineViewDelegate: NSObject, NSOutlineViewDelegate {
        private unowned let viewModel: ViewModel

        init(viewModel: ViewModel) {
            self.viewModel = viewModel
            super.init()
        }
    }
}
