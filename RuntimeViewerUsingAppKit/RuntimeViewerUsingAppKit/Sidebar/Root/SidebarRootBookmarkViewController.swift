import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

final class SidebarRootBookmarkViewController: SidebarRootViewController<SidebarRootBookmarkViewModel> {
    
    override var isReorderable: Bool { true }
    
    private let removeBookmarkRelay = PublishRelay<Int>()

    private let noBookmarkLabel = Label()

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            noBookmarkLabel
        }

        noBookmarkLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.top.leading.greaterThanOrEqualTo(16).priority(.high)
            make.bottom.trailing.lessThanOrEqualTo(-16)
        }

        noBookmarkLabel.do {
            $0.stringValue = "No Bookmark"
            $0.font = .systemFont(ofSize: 18, weight: .regular)
            $0.textColor = .secondaryLabelColor
        }
    }

    override func setupBindings(for viewModel: SidebarRootBookmarkViewModel) {
        super.setupBindings(for: viewModel)

        let input = SidebarRootBookmarkViewModel.Input(
            moveBookmark: outlineView.rx.nodeMoved().asSignal(),
            removeBookmark: removeBookmarkRelay.asSignal(),
        )

        let output = viewModel.transform(input)
        
        output.isMoveBookmarkEnabled.drive(outlineView.rx.isReorderingEnabled).disposed(by: rx.disposeBag)
        
        output.isBookmarkEmpty.not().drive(noBookmarkLabel.rx.isHidden).disposed(by: rx.disposeBag)
        
        output.isBookmarkEmpty.drive(scrollView.rx.isHidden).disposed(by: rx.disposeBag)
        
        Driver.just(true).drive(outlineView.rx.isRootLevelReorderingOnly).disposed(by: rx.disposeBag)
    }

    /// Only a bookmark row can be removed: the rows below one are its image's folders and files.
    override func contextMenuItems(for cellViewModel: SidebarRootCellViewModel, clickedRow: Int) -> [ContextMenuItem] {
        var items = super.contextMenuItems(for: cellViewModel, clickedRow: clickedRow)
        if outlineView.parent(forItem: cellViewModel) == nil, let index = outlineView.rootIndex(forRow: clickedRow) {
            items.append(
                ContextMenuItem(title: "Remove Bookmark", image: SFSymbols(systemName: .bookmark).nsuiImage) { [weak self] in
                    guard let self else { return }
                    removeBookmarkRelay.accept(index)
                }
            )
        }
        return items
    }
}
