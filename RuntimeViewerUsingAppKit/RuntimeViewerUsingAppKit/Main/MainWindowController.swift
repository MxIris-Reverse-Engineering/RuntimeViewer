import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures

class MainWindow: NSWindow {
    static let identifier: NSUserInterfaceItemIdentifier = "com.JH.RuntimeViewer.MainWindow"
    static let frameAutosaveName = "com.JH.RuntimeViewer.MainWindow.FrameAutosaveName"

    init() {
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    }
}

extension Reactive where Base: NSMenu {
    func selectedItemIndex() -> ControlEvent<Int> {
        let source = itemSelected(Any?.self).compactMap { [weak base] menuItem, _ -> Int? in
            guard let self = base else { return nil }
            return self.items.firstIndex(of: menuItem)
        }.share()
        return ControlEvent(events: source)
    }
}

protocol MainMenuItemRepresentable: RxMenuItemRepresentable {
    var icon: NSImage { get }
}

extension Reactive where Base: NSPopUpButton {
    func items<MenuItemRepresentable: MainMenuItemRepresentable>() -> Binder<[MenuItemRepresentable]> {
        Binder(base) { (target: NSPopUpButton, items: [MenuItemRepresentable]) in
            target.removeAllItems()
            items.forEach { item in
                target.addItem(withTitle: item.title)
                if let menuItem = target.item(withTitle: item.title) {
                    menuItem.image = item.icon
                }
            }
        }
    }
}

class MainWindowController: XiblessWindowController<MainWindow> {
    lazy var toolbarController = MainToolbarController(delegate: self)

    lazy var splitViewController = MainSplitViewController()

    var viewModel: MainViewModel?

    func setupBindings(for viewModel: MainViewModel) {
        rx.disposeBag = DisposeBag()
        self.viewModel = viewModel

        let input = MainViewModel.Input(
            sidebarBackClick: toolbarController.sidebarBackItem.button.rx.click.asSignal(),
            contentBackClick: toolbarController.contentBackItem.button.rx.click.asSignal(),
            saveClick: toolbarController.saveItem.button.rx.click.asSignal(),
            switchSource: toolbarController.switchSourceItem.popUpButton.rx.selectedItemIndex().asSignal(),
            generationOptionsClick: toolbarController.generationOptionsItem.button.rx.clickWithSelf.asSignal().map { $0 },
            fontSizeSmallerClick: toolbarController.fontSizeSmallerItem.button.rx.click.asSignal(),
            fontSizeLargerClick: toolbarController.fontSizeLargerItem.button.rx.click.asSignal(),
            loadFrameworksClick: toolbarController.loadFrameworksItem.button.rx.click.asSignal(),
            installHelperClick: toolbarController.installHelperItem.button.rx.click.asSignal(),
            attachToProcessClick: toolbarController.attachItem.button.rx.click.asSignal()
        )
        let output = viewModel.transform(input)
        output.sharingServiceItems.bind(to: toolbarController.sharingServicePickerItem.rx.items).disposed(by: rx.disposeBag)
        output.isSavable.drive(toolbarController.saveItem.button.rx.isEnabled).disposed(by: rx.disposeBag)
        output.isSidebarBackHidden.drive(toolbarController.sidebarBackItem.button.rx.isHidden).disposed(by: rx.disposeBag)
        output.selectedRuntimeSourceIndex.drive(toolbarController.switchSourceItem.popUpButton.rx.selectedIndex()).disposed(by: rx.disposeBag)
        output.runtimeSources.drive(toolbarController.switchSourceItem.popUpButton.rx.items()).disposed(by: rx.disposeBag)
        viewModel.errorRelay.asSignal().emitOnNextMainActor { error in
            NSAlert(error: error).runModal()
        }
        .disposed(by: rx.disposeBag)
    }

    init() {
        super.init(windowGenerator: .init())
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        contentWindow.title = "Runtime Viewer"
        contentWindow.toolbar = toolbarController.toolbar
        contentWindow.identifier = MainWindow.identifier
        contentWindow.setFrame(.init(origin: .zero, size: .init(width: 1280, height: 800)), display: true)
        contentWindow.box.positionCenter()
        contentWindow.setFrameAutosaveName(MainWindow.frameAutosaveName)
    }
}

extension MainWindowController: MainToolbarController.Delegate {
    var splitView: NSSplitView {
        splitViewController.splitView
    }
}
