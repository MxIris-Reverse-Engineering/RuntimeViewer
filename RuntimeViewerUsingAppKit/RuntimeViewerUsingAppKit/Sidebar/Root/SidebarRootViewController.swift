import AppKit
import AppKitPlus
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class SidebarRootViewController<ViewModel: SidebarRootViewModel>: BaseViewController<ViewModel>, NSOutlineViewDelegate {
    var isReorderable: Bool {
        false
    }

    let (scrollView, outlineView): (ScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()

    private let filterSearchField = NSFilterSearchField()

    private let filterControlBar = NSFilterControlBar()

    private let bottomSeparatorView = NSBox()

    /// Runs the list under the tab switcher's bar and the filter bar from macOS 26 on. Made in
    /// `viewDidLoad`.
    private var navigatorScrollViewLayout: NavigatorScrollViewLayout?

    override var shouldDisplayCommonLoading: Bool {
        true
    }

    /// From macOS 26 the list reaches the top of the page, under the tab switcher's bar; the gap below
    /// that bar is in the list's content inset instead.
    override var contentInsets: NSDirectionalEdgeInsets {
        if #available(macOS 26.0, *) {
            .init()
        } else {
            super.contentInsets
        }
    }

    /// The list takes keyboard focus when the sidebar pops back to it — see the same override in
    /// `SidebarRuntimeObjectViewController`.
    override var preferredFirstResponder: NSResponder? {
        outlineView.window != nil ? outlineView : nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.hierarchy {
            scrollView
            bottomSeparatorView
            filterControlBar
        }

        scrollView.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
            if #available(macOS 26.0, *) {
                // Under the filter bar as well, which floats over the list's bottom edge.
                make.bottom.equalToSuperview()
            } else {
                make.bottom.equalTo(bottomSeparatorView.snp.top)
            }
        }

        bottomSeparatorView.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
            make.bottom.equalTo(filterControlBar.snp.top)
            make.height.equalTo(1)
        }

        // The bar's intrinsic height carries the margins around the field.
        filterControlBar.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
            if #available(macOS 26.0, *) {
                make.bottom.equalTo(view.layoutGuide(for: .safeArea()))
            } else {
                make.bottom.equalToSuperview()
            }
        }

        bottomSeparatorView.do {
            $0.boxType = .separator
            // From macOS 26 the rows fade out under the bar instead, as in Xcode.
            if #available(macOS 26.0, *) {
                $0.isHidden = true
            }
        }

        navigatorScrollViewLayout = NavigatorScrollViewLayout(scrollView: scrollView, bottomOverlayViews: [filterControlBar])

        // The bar sets the field's control size, which sets its font, so the field's own settings come after it.
        filterControlBar.do {
            $0.filterField = filterSearchField
            $0.controlSize = .large
        }

        scrollView.do {
            $0.autohidesScrollers = true
            $0.hidesVisualEffectView = true
        }
        
        outlineView.do {
            $0.style = .sourceList
        }
    }

    override func setupBindings(for viewModel: ViewModel) {
        super.setupBindings(for: viewModel)

        let input = ViewModel.Input(
            clickedNode: outlineView.rx.modelDoubleClicked().asSignal(),
            selectedNode: outlineView.rx.modelSelected().asSignal(),
            searchString: filterSearchField.rx.stringValue.asSignal()
        )

        let output = viewModel.transform(input)

        output.nodes.drive(outlineView.rx.nodes(options: isReorderable ? [.reorderable] : []))({ (outlineView: NSOutlineView, tableColumn: NSTableColumn?, node: SidebarRootCellViewModel) -> NSView? in
            let cellView = outlineView.box.makeView(ofClass: SidebarRootTableCellView.self)
            cellView.bind(to: node)
            return cellView
        }, { outlineView, _ -> NSTableRowView? in
            if #available(macOS 26.0, *) {
                return outlineView.box.makeView(ofClass: SidebarTableRowView.self)
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
            .subscribeOnNext { [weak self, weak viewModel] _ in
                guard let self, let viewModel else { return }
                
                // Keyed on the scope, never on `source.description`. That is the
                // peer's *process* display name, so two devices each running a
                // SpringBoard — the case simulator injection exists for — wrote
                // one another's expansion state.
                let scopeKey = viewModel.documentState.runtimeEngine.bookmarkScope.sidebarAutosaveKey
                outlineView.identifier = "com.JH.RuntimeViewer.\(Self.self).identifier.\(scopeKey)"

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
                outlineView.expansionAutosaveName = "com.JH.RuntimeViewer.\(Self.self).autosaveName.\(scopeKey)"
                outlineView.restoreExpansionFromAutosave()
            }
            .disposed(by: rx.disposeBag)
        
        output.toggleExpansion
            .emitOnNextMainActor { [weak self] item, maxDepth in
                guard let self else { return }
                if outlineView.isItemExpanded(item) {
                    outlineView.collapseItem(item)
                } else {
                    outlineView.expandItem(item, toDepth: maxDepth)
                }
            }
            .disposed(by: rx.disposeBag)
        
        outlineView.rx.setDelegate(self).disposed(by: rx.disposeBag)
    }
    
    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard let cellViewModel = item as? SidebarRootCellViewModel else { return nil }
        return cellViewModel.appearance.name.string
    }
}
