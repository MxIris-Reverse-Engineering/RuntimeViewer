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
        if #available(macOS 26.0, *) {
            output.isSidebarBackHidden.drive(with: self, onNext: { $0.toolbarController.sidebarBackItem.isHidden = $1 }).disposed(by: rx.disposeBag)
        } else {
            output.isSidebarBackHidden.drive(toolbarController.sidebarBackItem.button.rx.isHidden).disposed(by: rx.disposeBag)
        }
        output.selectedRuntimeSourceIndex.drive(toolbarController.switchSourceItem.popUpButton.rx.selectedIndex()).disposed(by: rx.disposeBag)
        output.runtimeSources.drive(toolbarController.switchSourceItem.popUpButton.rx.items()).disposed(by: rx.disposeBag)

        viewModel.errorRelay
            .asSignal()
            .emitOnNextMainActor { [weak self] error in
                guard let self else { return }
                NSAlert(error: error).beginSheetModal(for: contentWindow)
            }
            .disposed(by: rx.disposeBag)
        
        contentWindow.identifier = "com.JH.RuntimeViewer.\(Self.self).identifier.\(viewModel.appServices.runtimeEngine.source.description)"
        contentWindow.setFrameAutosaveName("com.JH.RuntimeViewer.\(Self.self).autosaveName.\(viewModel.appServices.runtimeEngine.source.description)")
    }

    init() {
        super.init(windowGenerator: .init())
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        contentWindow.title = "Runtime Viewer"
        contentWindow.toolbar = toolbarController.toolbar
        contentWindow.setFrame(.init(origin: .zero, size: .init(width: 1280, height: 800)), display: true)
        contentWindow.box.positionCenter()
    }
}

extension MainWindowController: MainToolbarController.Delegate {}
