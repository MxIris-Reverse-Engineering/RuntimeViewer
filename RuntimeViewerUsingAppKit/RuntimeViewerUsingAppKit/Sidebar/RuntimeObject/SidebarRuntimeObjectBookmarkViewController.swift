import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerApplication

final class SidebarRuntimeObjectBookmarkViewController: SidebarRuntimeObjectViewController<SidebarRuntimeObjectBookmarkViewModel> {
    
    override var isReorderable: Bool { true }
    
    private let removeBookmarkRelay = PublishRelay<Int>()
    
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
    
    override func contextMenuItems(for cellViewModel: SidebarRuntimeObjectCellViewModel, clickedRow: Int) -> [SidebarRuntimeObjectMenuItem] {
        var items = super.contextMenuItems(for: cellViewModel, clickedRow: clickedRow)
        // Only root-level bookmark rows can be removed; nested specialization
        // children have no standalone bookmark to delete.
        if outlineView.parent(forItem: cellViewModel) == nil, let index = outlineView.rootIndex(forRow: clickedRow) {
            items.append(
                SidebarRuntimeObjectMenuItem(title: "Remove Bookmark", image: SFSymbols(systemName: .bookmark).nsuiImgae) { [weak self] in
                    guard let self else { return }
                    removeBookmarkRelay.accept(index)
                }
            )
        }
        return items
    }
}

extension NSOutlineView {
    func rootIndex(forRow row: Int) -> Int? {
        guard row >= 0, let initialItem = self.item(atRow: row) else {
            return nil
        }
        
        var currentItem = initialItem
        
        while let parent = self.parent(forItem: currentItem) {
            currentItem = parent
        }
        
        let index = self.childIndex(forItem: currentItem)
        
        return index != -1 ? index : nil
    }
}
