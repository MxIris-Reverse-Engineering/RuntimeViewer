import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerApplication

final class SidebarRuntimeObjectBookmarkViewController: SidebarRuntimeObjectViewController<SidebarRuntimeObjectBookmarkViewModel> {
    
    override var isReorderable: Bool { true }
    
    private let removeBookmarkRelay = PublishRelay<SidebarRuntimeObjectCellViewModel>()

    /// Edit ▸ Copy (⌘C): the selected row's name.
    @objc func copy(_ sender: Any?) {
        copySelectedRowName()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(copy(_:)) {
            return canCopySelectedRowName
        }
        return super.responds(to: aSelector)
    }

    /// Delete removes the selected bookmark, as its context menu's Remove
    /// Bookmark does — only on a bookmark row, not on a specialization
    /// listed below one.
    override func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.isDeleteKeyPress, let selectedCellViewModel, outlineView.parent(forItem: selectedCellViewModel) == nil
        else { return super.handleKeyDown(event) }
        removeBookmarkRelay.accept(selectedCellViewModel)
        return true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        imageLoadedView.emptyLabel.do {
            $0.font = .systemFont(ofSize: 18, weight: .regular)
            $0.textColor = .secondaryLabelColor
        }
    }
    
    override func setupBindings(for viewModel: SidebarRuntimeObjectBookmarkViewModel) {
        super.setupBindings(for: viewModel)
        
        let input = SidebarRuntimeObjectBookmarkViewModel.Input(
            moveBookmark: outlineView.rx.nodeMoved().asSignal(),
            removeBookmark: removeBookmarkRelay.asSignal(),
        )
        
        let output = viewModel.transform(input)
        
        output.isMoveBookmarkEnabled.drive(outlineView.rx.isReorderingEnabled).disposed(by: rx.disposeBag)
        
        Driver.just(true).drive(outlineView.rx.isRootLevelReorderingOnly).disposed(by: rx.disposeBag)
        
        imageLoadedView.emptyLabel.stringValue = "No Bookmarks"
    }
    
    override func contextMenuItems(for cellViewModel: SidebarRuntimeObjectCellViewModel, clickedRow: Int) -> [ContextMenuItem] {
        var items = super.contextMenuItems(for: cellViewModel, clickedRow: clickedRow)
        // Only root-level bookmark rows can be removed; nested specialization
        // children have no standalone bookmark to delete.
        if outlineView.parent(forItem: cellViewModel) == nil {
            items.append(
                ContextMenuItem(title: "Remove Bookmark", image: SFSymbols(systemName: .bookmark).nsuiImage) { [weak self] in
                    guard let self else { return }
                    removeBookmarkRelay.accept(cellViewModel)
                }
            )
        }
        return items
    }
}
