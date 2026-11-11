import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class SidebarRootDirectoryViewController: SidebarRootViewController<SidebarRootDirectoryViewModel> {
    private let addToBookmarkRelay = PublishRelay<SidebarRootCellViewModel>()

    override func setupBindings(for viewModel: SidebarRootDirectoryViewModel) {
        super.setupBindings(for: viewModel)

        let input = SidebarRootDirectoryViewModel.Input(
            addBookmark: addToBookmarkRelay.asSignal()
        )

        _ = viewModel.transform(input)
    }

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

    override func contextMenuItems(for cellViewModel: SidebarRootCellViewModel, clickedRow: Int) -> [ContextMenuItem] {
        super.contextMenuItems(for: cellViewModel, clickedRow: clickedRow) + [
            ContextMenuItem(title: "Add Item to Bookmark", image: SFSymbols(systemName: .bookmark).nsuiImage) { [weak self] in
                guard let self else { return }
                addToBookmarkRelay.accept(cellViewModel)
                SystemHUD.default.configuration = .addToBookmarkHUDConfiguration
                SystemHUD.default.show(delay: 1)
            },
        ]
    }
}

extension SystemHUD.Configuration {
    static let addToBookmarkHUDConfiguration = SystemHUD.Configuration(
        image: SFSymbols(systemName: .bookmarkFill, pointSize: 90, weight: .medium).nsuiImage,
        title: "Added Bookmark"
    )
}
