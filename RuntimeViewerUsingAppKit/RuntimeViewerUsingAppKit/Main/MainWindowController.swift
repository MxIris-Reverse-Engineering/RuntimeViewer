import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import UniformTypeIdentifiers

final class MainWindow: NSWindow {
    static let identifier: NSUserInterfaceItemIdentifier = "com.JH.RuntimeViewer.MainWindow"
    static let frameAutosaveName = "com.JH.RuntimeViewer.MainWindow.FrameAutosaveName"

    init() {
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

final class MainWindowController: XiblessWindowController<MainWindow> {
    let documentState: DocumentState

    private(set) lazy var toolbarController = MainToolbarController(delegate: self)

    private(set) lazy var splitViewController = MainSplitViewController()

    private var viewModel: MainViewModel?

    private let frameworksSelectedRelay = PublishRelay<[URL]>()

    private let saveLocationSelectedRelay = PublishRelay<URL>()

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(windowGenerator: .init())
    }

    override func synchronizeWindowTitleWithDocumentName() {
        // Prevent NSDocument from overriding the window title with "Untitled"
        contentWindow.title = documentState.runtimeEngine.source.description
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        contentWindow.title = documentState.runtimeEngine.source.description
        contentWindow.titleVisibility = .hidden
        contentWindow.toolbar = toolbarController.toolbar
        contentWindow.setFrame(.init(origin: .zero, size: .init(width: 1280, height: 800)), display: true)
        contentWindow.box.positionCenter()
        contentWindow.identifier = .makeIdentifier(of: Self.self)
        contentWindow.setFrameAutosaveName("com.JH.RuntimeViewer.\(Self.self).autosaveName")
        contentWindow.animationBehavior = .documentWindow
    }

    func setupBindings(for viewModel: MainViewModel) {
        rx.disposeBag = DisposeBag()

        self.viewModel = viewModel

        splitViewController.setupBindings(for: viewModel)

        documentState.$currentImageName
            .asDriver()
            .driveOnNext { [weak self] imageName in
                guard let self else { return }
                var title = documentState.runtimeEngine.source.description

                if let imageName {
                    title += " - \(imageName)"
                }

                contentWindow.title = title
                if let imageName {
                    toolbarController.titleItem.displayTitle = imageName
                } else {
                    toolbarController.titleItem.displayTitle = "RuntimeViewer"
                }
            }
            .disposed(by: rx.disposeBag)

        documentState.$currentSubtitle
            .asDriver()
            .driveOnNext { [weak self] subtitle in
                guard let self else { return }
                toolbarController.titleItem.displaySubtitle = subtitle
            }
            .disposed(by: rx.disposeBag)

        let input = MainViewModel.Input(
            sidebarBackClick: toolbarController.sidebarBackItem.button.rx.click.asSignal(),
            contentBackClick: toolbarController.contentBackItem.button.rx.click.asSignal(),
            saveClick: toolbarController.saveItem.button.rx.click.asSignal(),
            switchSource: toolbarController.switchSourceItem.popUpButton.rx.selectedItemIndex().asSignal(),
            generationOptionsClick: toolbarController.generationOptionsItem.button.rx.clickWithSelf.asSignal().map { $0 },
            fontSizeSmallerClick: toolbarController.fontSizeSmallerItem.button.rx.click.asSignal(),
            fontSizeLargerClick: toolbarController.fontSizeLargerItem.button.rx.click.asSignal(),
            loadFrameworksClick: toolbarController.loadFrameworksItem.button.rx.click.asSignal(),
            attachToProcessClick: toolbarController.attachItem.button.rx.click.asSignal(),
            frameworksSelected: frameworksSelectedRelay.asSignal(),
            saveLocationSelected: saveLocationSelectedRelay.asSignal()
        )
        let output = viewModel.transform(input)

        output.sharingServiceData
            .map { items -> [Any] in
                items.map { data in
                    let icon: NSImage
                    let ext: String
                    switch data.iconType {
                    case .c,
                         .objc:
                        ext = "h"
                        icon = NSWorkspace.shared.icon(for: .cHeader)
                    case .swift:
                        ext = "swiftinterface"
                        icon = NSWorkspace.shared.icon(for: .swiftSource)
                    }
                    return NSPreviewRepresentingActivityItem(item: data.provider, title: data.title + "." + ext, image: nil, icon: icon)
                }
            }
            .bind(to: toolbarController.sharingServicePickerItem.rx.items)
            .disposed(by: rx.disposeBag)

        output.requestFrameworkSelection.emitOnNext { [weak self] in
            guard let self else { return }
            presentOpenPanel()
        }
        .disposed(by: rx.disposeBag)

        output.requestSaveLocation.emitOnNext { [weak self] name, type in
            guard let self else { return }
            presentSavePanel(name: name, type: type)
        }.disposed(by: rx.disposeBag)

        output.isSavable.drive(toolbarController.saveItem.button.rx.isEnabled).disposed(by: rx.disposeBag)

        output.isSidebarBackHidden.drive(toolbarController.sidebarBackItem.rx.isHidden).disposed(by: rx.disposeBag)

        output.isContentBackHidden.drive(toolbarController.contentBackItem.rx.isHidden).disposed(by: rx.disposeBag)

        output.selectedRuntimeSourceIndex.drive(toolbarController.switchSourceItem.popUpButton.rx.selectedIndex()).disposed(by: rx.disposeBag)

        output.runtimeSources.drive(toolbarController.switchSourceItem.popUpButton.rx.items()).disposed(by: rx.disposeBag)

        viewModel.errorRelay
            .asSignal()
            .emitOnNextMainActor { [weak self] error in
                guard let self else { return }
                NSAlert(error: error).beginSheetModal(for: contentWindow)
            }
            .disposed(by: rx.disposeBag)
    }

    private func presentOpenPanel() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.framework]
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = true
        openPanel.beginSheetModal(for: contentWindow) { [weak self] response in
            guard let self, response == .OK else { return }
            frameworksSelectedRelay.accept(openPanel.urls)
        }
    }

    private func presentSavePanel(name: String, type: UTType) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [type]
        savePanel.nameFieldStringValue = name
        savePanel.beginSheetModal(for: contentWindow) { [weak self] response in
            guard let self, response == .OK, let url = savePanel.url else { return }
            saveLocationSelectedRelay.accept(url)
        }
    }
    
//    @IBAction func exportInterface(_ sender: Any?) {
//        viewModel?.router.trigger(.exportInterfaces)
//    }
}

extension MainWindowController: MainToolbarController.Delegate {}

extension NSUserInterfaceItemIdentifier {
    static func makeIdentifier<T>(of type: T.Type) -> Self {
        "com.JH.RuntimeViewer.\(T.self).identifier"
    }
}
