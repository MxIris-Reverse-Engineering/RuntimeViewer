import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

final class SidebarRootBookmarkViewController: SidebarRootViewController<SidebarRootBookmarkViewModel> {
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

        outlineView.do {
            $0.menu = NSMenu().then {
                $0.delegate = self
            }
        }
    }

    override func setupBindings(for viewModel: SidebarRootBookmarkViewModel) {
        super.setupBindings(for: viewModel)

        let input = SidebarRootBookmarkViewModel.Input(
            removeBookmark: removeBookmarkRelay.asSignal()
        )

        let output = viewModel.transform(input)
        
        output.isEmptyBookmark.not().drive(noBookmarkLabel.rx.isHidden).disposed(by: rx.disposeBag)
        
        output.isEmptyBookmark.drive(scrollView.rx.isHidden).disposed(by: rx.disposeBag)
    }

    @objc private func removeBookmarkMenuItemAction(_ sender: NSMenuItem) {
        guard outlineView.hasValidClickedRow, let index = sender.representedObject as? Int else { return }
        removeBookmarkRelay.accept(index)
    }
}

extension SidebarRootBookmarkViewController: NSMenuDelegate {
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
