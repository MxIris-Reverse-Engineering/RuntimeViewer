import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerApplication

final class SidebarRuntimeObjectBookmarkViewController: SidebarRuntimeObjectViewController<SidebarRuntimeObjectBookmarkViewModel> {
    
    private let removeBookmarkRelay = PublishRelay<Int>()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        imageLoadedView.emptyLabel.do {
            $0.font = .systemFont(ofSize: 18, weight: .regular)
            $0.textColor = .secondaryLabelColor
        }
        
        outlineView.do {
            $0.menu = NSMenu().then {
                $0.delegate = self
            }
        }
    }
    
    override func setupBindings(for viewModel: SidebarRuntimeObjectBookmarkViewModel) {
        super.setupBindings(for: viewModel)
        
        let input = SidebarRuntimeObjectBookmarkViewModel.Input(
            removeBookmark: removeBookmarkRelay.asSignal(),
        )
        
        _ = viewModel.transform(input)
        
        imageLoadedView.emptyLabel.stringValue = "No Bookmarks"
    }
    
    @objc private func removeBookmarkMenuItemAction(_ sender: NSMenuItem) {
        guard outlineView.hasValidClickedRow, let index = sender.representedObject as? Int else { return }
        removeBookmarkRelay.accept(index)
    }
}

extension SidebarRuntimeObjectBookmarkViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard outlineView.hasValidClickedRow else { return }
        
        if outlineView.parent(forItem: outlineView.itemAtClickedRow) == nil, let index = outlineView.rootIndex(forRow: outlineView.clickedRow) {
            menu.removeAllItems()
            menu.addItem(withTitle: "Remove Bookmark", action: #selector(removeBookmarkMenuItemAction(_:)), keyEquivalent: "").then {
                $0.image = SFSymbols(systemName: .bookmark).nsuiImgae
                $0.representedObject = index
            }
        } else {
            menu.removeAllItems()
        }
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
