import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class SidebarRootDirectoryViewController: SidebarRootViewController<SidebarRootDirectoryViewModel> {
    private let addToBookmarkRelay = PublishRelay<SidebarRootCellViewModel>()

    private let addToBookmarkHUD = SystemHUD(
        configuration: .init(
            image: SFSymbols(systemName: .bookmarkFill, pointSize: 90, weight: .medium).nsuiImgae,
            title: "Added Bookmark"
        )
    )

    override func viewDidLoad() {
        super.viewDidLoad()

        outlineView.do {
            $0.menu = NSMenu().then {
                $0.addItem(withTitle: "Add Item to Bookmark", action: #selector(addToBookmarkMenuItemAction(_:)), keyEquivalent: "").then {
                    $0.image = SFSymbols(systemName: .bookmark).nsuiImgae
                }
            }
        }
    }

    @objc private func addToBookmarkMenuItemAction(_ sender: NSMenuItem) {
        guard outlineView.hasValidClickedRow, let cellViewModel = outlineView.itemAtClickedRow as? SidebarRootCellViewModel else { return }
        addToBookmarkRelay.accept(cellViewModel)
        addToBookmarkHUD.show(delay: 1)
    }

    override func setupBindings(for viewModel: SidebarRootDirectoryViewModel) {
        super.setupBindings(for: viewModel)

        let input = SidebarRootDirectoryViewModel.Input(
            addBookmark: addToBookmarkRelay.asSignal()
        )

        _ = viewModel.transform(input)
    }
}
