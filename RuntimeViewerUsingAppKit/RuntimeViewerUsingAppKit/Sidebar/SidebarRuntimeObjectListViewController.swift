import AppKit
import FoundationToolbox
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerApplication

final class SidebarRuntimeObjectListViewController: SidebarRuntimeObjectViewController<SidebarRuntimeObjectListViewModel> {
    private let openQuicklyActionBar = DSFQuickActionBar()

    private let openQuicklyActivateRelay = PublishRelay<SidebarRuntimeObjectCellViewModel>()

    private let searchStringDidChangeForOpenQuickly = PublishRelay<String>()

    private var currentSearchTask: DSFQuickActionBar.SearchTask?

    private let addToBookmarkRelay = PublishRelay<SidebarRuntimeObjectCellViewModel>()

    private let addToBookmarkHUD = SystemHUD(
        configuration: .init(
            image: SFSymbols(systemName: .bookmarkFill, pointSize: 90, weight: .medium).nsuiImgae,
            title: "Added Bookmark"
        )
    )

    @Dependency(\.appDefaults)
    private var appDefaults

    override func viewDidLoad() {
        super.viewDidLoad()

        openQuicklyActionBar.do {
            $0.contentSource = self
        }

        outlineView.do {
            $0.menu = NSMenu().then {
                $0.addItem(withTitle: "Add Item to Bookmark", action: #selector(addToBookmarkMenuItemAction(_:)), keyEquivalent: "").then {
                    $0.image = SFSymbols(systemName: .bookmark).nsuiImgae
                }
            }
        }
    }

    override func setupBindings(for viewModel: SidebarRuntimeObjectListViewModel) {
        super.setupBindings(for: viewModel)

        let input = SidebarRuntimeObjectListViewModel.Input(
            runtimeObjectClickedForOpenQuickly: openQuicklyActivateRelay.asSignal(),
            searchStringForOpenQuickly: searchStringDidChangeForOpenQuickly.asSignal(),
            addBookmark: addToBookmarkRelay.asSignal()
        )

        let output = viewModel.transform(input)

        output.runtimeObjectsForOpenQuickly.driveOnNextMainActor { [weak self] viewModels in
            guard let self else { return }
            currentSearchTask?.complete(with: viewModels)
            currentSearchTask = nil
        }
        .disposed(by: rx.disposeBag)

        output.selectRuntimeObject.emitOnNextMainActor { [weak self] item in
            guard let self else { return }
            let outlineView = outlineView
            let row = outlineView.row(forItem: item)
            guard row >= 0, row < outlineView.numberOfRows else { return }
            outlineView.selectRowIndexes(.init(integer: row), byExtendingSelection: false)
            guard !outlineView.visibleRowIndexes.contains(row) else { return }
            outlineView.box.scrollRowToVisible(row, animated: false, scrollPosition: .centeredVertically)
        }
        .disposed(by: rx.disposeBag)
    }

    @ArrayBuilder<Selector>
    override func lateResponderSelectors() -> [Selector] {
        #selector(openQuickly(_:))
        #selector(exportInterface(_:))
    }

    @IBAction func openQuickly(_ sender: Any?) {
        openQuicklyActionBar.cancel()
        openQuicklyActionBar.present(
            parentWindow: view.window,
            placeholderText: "Open Quickly",
            searchImage: nil,
            initialSearchText: nil,
            showKeyboardShortcuts: false,
            canBecomeMainWindow: false
        ) {}
    }

    @IBAction func exportInterface(_ sender: Any?) {
        viewModel?.router.trigger(.exportInterface)
    }

    @objc private func addToBookmarkMenuItemAction(_ sender: NSMenuItem) {
        guard outlineView.hasValidClickedRow, let cellViewModel = outlineView.itemAtClickedRow as? SidebarRuntimeObjectCellViewModel else { return }
        addToBookmarkRelay.accept(cellViewModel)
        addToBookmarkHUD.show(delay: 1)
    }
    
    override func responds(to aSelector: Selector!) -> Bool {
        guard let aSelector else { return super.responds(to: aSelector) }
        switch aSelector {
        case #selector(exportInterface(_:)), #selector(openQuickly(_:)):
            return viewModel?.loadState == .loaded
        default:
            return super.responds(to: aSelector)
        }
    }
}

extension SidebarRuntimeObjectListViewController: DSFQuickActionBarContentSource {
    func quickActionBar(_ quickActionBar: DSFQuickActionBar, viewForItem item: AnyHashable, searchTerm: String) -> NSView? {
        guard let viewModel = item as? SidebarRuntimeObjectCellViewModel else { return nil }
        let cellView = quickActionBar.dequeueView() ?? SidebarRuntimeObjectCellView(forOpenQuickly: true)
        cellView.bind(to: viewModel)
        return cellView
    }

    func quickActionBar(_ quickActionBar: DSFQuickActionBar, itemsForSearchTermTask task: DSFQuickActionBar.SearchTask) {
        currentSearchTask = task
        searchStringDidChangeForOpenQuickly.accept(task.searchTerm)
    }

    func quickActionBar(_ quickActionBar: DSFQuickActionBar, didActivateItem item: AnyHashable) {
        guard let viewModel = item as? SidebarRuntimeObjectCellViewModel else { return }
        openQuicklyActivateRelay.accept(viewModel)
    }
}

extension DSFQuickActionBar: Then {}
