import AppKit
import FoundationToolbox
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerApplication

final class SidebarRuntimeObjectListViewController: SidebarRuntimeObjectViewController<SidebarRuntimeObjectListViewModel> {
    override var supportsSections: Bool { true }

    private let addToBookmarkRelay = PublishRelay<SidebarRuntimeObjectCellViewModel>()

    @Dependency(\.appDefaults)
    private var appDefaults

    override func setupBindings(for viewModel: SidebarRuntimeObjectListViewModel) {
        super.setupBindings(for: viewModel)

        let input = SidebarRuntimeObjectListViewModel.Input(
            runtimeObjectClickedForOpenQuickly: .empty(),
            searchStringForOpenQuickly: .empty(),
            addBookmark: addToBookmarkRelay.asSignal()
        )

        let output = viewModel.transform(input)

        output.selectRuntimeObject.emitOnNextMainActor { [weak self] item in
            guard let self else { return }
            outlineView.selectRowBringingIntoView(outlineView.row(forItem: item))
        }
        .disposed(by: rx.disposeBag)

        output.selectCell.emitOnNextMainActor { [weak self] result in
            guard let self else { return }
            for ancestor in result.ancestors where !outlineView.isItemExpanded(ancestor) {
                outlineView.expandItem(ancestor)
            }
            outlineView.selectRowBringingIntoView(outlineView.row(forItem: result.cell))
        }
        .disposed(by: rx.disposeBag)

        // Runs a main-actor turn after the view model resolved the request, by
        // when the coordinator has switched to this tab and a filter the view
        // model cleared has been reloaded into the outline.
        output.revealCell.emitOnNextMainActor { [weak self] result in
            guard let self else { return }
            revealRow(for: result)
        }
        .disposed(by: rx.disposeBag)

        output.revealFailed.emitOnNext {
            NSSound.beep()
        }
        .disposed(by: rx.disposeBag)
    }

    /// Expands everything between the list's root and the cell — its kind
    /// section, then its ancestors — selects its row, brings the row on screen
    /// and gives the list keyboard focus, so the arrow keys continue from it.
    private func revealRow(for result: SidebarRuntimeObjectListViewModel.CellLookup) {
        let topLevelCell = result.ancestors.first ?? result.cell
        if let section = sectionItem(containing: topLevelCell), !outlineView.isItemExpanded(section) {
            outlineView.expandItem(section)
        }
        for ancestor in result.ancestors where !outlineView.isItemExpanded(ancestor) {
            outlineView.expandItem(ancestor)
        }
        outlineView.selectRowBringingIntoView(outlineView.row(forItem: result.cell))
        view.window?.makeFirstResponder(outlineView)
    }

    /// The kind-section group row a top-level cell sits under. Sections can be
    /// collapsed, and a collapsed section's objects have no rows at all.
    ///
    /// The outline finds a section item by equality, which for
    /// `SidebarRuntimeObjectSection` is its kind alone — the same lookup the
    /// sections adapter relies on when it expands every section after a reload.
    private func sectionItem(containing topLevelCell: SidebarRuntimeObjectCellViewModel) -> SidebarRuntimeObjectSection? {
        for sectionIndex in 0 ..< outlineView.numberOfChildren(ofItem: nil) {
            guard let section = outlineView.child(sectionIndex, ofItem: nil) as? SidebarRuntimeObjectSection,
                  section.kind == topLevelCell.runtimeObject.kind
            else { continue }
            return section
        }
        return nil
    }

    override func contextMenuItems(for cellViewModel: SidebarRuntimeObjectCellViewModel, clickedRow: Int) -> [ContextMenuItem] {
        super.contextMenuItems(for: cellViewModel, clickedRow: clickedRow) + [
            ContextMenuItem(title: "Add Item to Bookmark", image: SFSymbols(systemName: .bookmark).nsuiImage) { [weak self] in
                guard let self else { return }
                addToBookmarkRelay.accept(cellViewModel)
                SystemHUD.default.configuration = .addToBookmarkHUDConfiguration
                SystemHUD.default.show(delay: 1)
            },
        ]
    }

    /// Edit ▸ Copy (⌘C): the selected row's name.
    @objc func copy(_ sender: Any?) {
        copySelectedRowName()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        guard let aSelector else { return super.responds(to: aSelector) }
        switch aSelector {
        case #selector(copy(_:)):
            return canCopySelectedRowName
        default:
            return super.responds(to: aSelector)
        }
    }
}
