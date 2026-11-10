import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerCommunication
import RuntimeViewerCore
import RuntimeViewerCatalystExtensions
import RxCocoa
import RxSwift
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

    /// The runtime source pickers' list: the popover either picker opens.
    private let runtimeSourcePopoverAdapter = RuntimeSourcePopoverAdapter()

    /// The classic toolbar's runtime source pop-up, filled from the same list.
    private lazy var runtimeSourceMenuAdapter = RuntimeSourceMenuAdapter(popUpButton: toolbarController.switchSourcePopUpItem.popUpButton)

    private let increaseFontSizeRelay = PublishRelay<Void>()

    private let decreaseFontSizeRelay = PublishRelay<Void>()

    private let resetFontSizeRelay = PublishRelay<Void>()

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
        contentWindow.box.centerInScreen()
        contentWindow.identifier = .makeIdentifier(of: Self.self)
        contentWindow.setFrameAutosaveName("com.JH.RuntimeViewer.\(Self.self).autosaveName")
        contentWindow.animationBehavior = .documentWindow
        contentWindow.toolbarStyle = .unified
        contentWindow.titlebarSeparatorStyle = .none
    }

    func setupBindings(for viewModel: MainViewModel) {
        rx.disposeBag = DisposeBag()

        self.viewModel = viewModel

        splitViewController.setupBindings(for: viewModel)

        let input = MainViewModel.Input(
            sidebarBackClick: toolbarController.sidebarBackItem.button.rx.click.asSignal(),
            navigationPreviousClick: toolbarController.navigationItem.segmentedControl.rx.selectedSegment.asSignal().filter { $0 == 0 }.mapToVoid(),
            navigationNextClick: toolbarController.navigationItem.segmentedControl.rx.selectedSegment.asSignal().filter { $0 == 1 }.mapToVoid(),
            navigationHistorySelected: Signal.merge(
                toolbarController.navigationItem.backwardHistoryMenu.rx.itemSelected(NavigationHistoryItem.self).asSignal(),
                toolbarController.navigationItem.forwardHistoryMenu.rx.itemSelected(NavigationHistoryItem.self).asSignal()
            ).map(\.item.index),
            saveClick: toolbarController.saveItem.button.rx.click.asSignal(),
            switchSource: Signal.merge(runtimeSourcePopoverAdapter.sourceSelected, runtimeSourceMenuAdapter.sourceSelected),
            generationOptionsClick: toolbarController.generationOptionsItem.button.rx.click.asSignal(),
            increaseFontSize: increaseFontSizeRelay.asSignal(),
            decreaseFontSize: decreaseFontSizeRelay.asSignal(),
            resetFontSize: resetFontSizeRelay.asSignal(),
            loadFrameworksClick: toolbarController.loadFrameworksItem.button.rx.click.asSignal(),
            attachToProcessClick: toolbarController.attachItem.button.rx.click.asSignal(),
            mcpStatusClick: toolbarController.mcpStatusItem.button.rx.click.asSignal(),
            activityClick: Signal.merge(
                toolbarController.activityItem.activityView.rx.controlEvent.asSignal(),
                toolbarController.activityTitleItem.activityIndicator?.rx.controlEvent.asSignal() ?? .empty()
            ),
            frameworksSelected: frameworksSelectedRelay.asSignal(),
            saveLocationSelected: saveLocationSelectedRelay.asSignal(),
            dependencyCacheSelected: Signal.merge(runtimeSourcePopoverAdapter.dependencyCacheSelected, runtimeSourceMenuAdapter.dependencyCacheSelected)
        )
        let output = viewModel.transform(input)

        output.isLoadFrameworksEnabled.drive(toolbarController.loadFrameworksItem.button.rx.isEnabled).disposed(by: rx.disposeBag)

        output.windowTitle.driveOnNext { [weak self] title in
            guard let self else { return }
            contentWindow.title = title
        }
        .disposed(by: rx.disposeBag)

        output.toolbarTitle.driveOnNext { [weak self] title in
            guard let self else { return }
            for titleItem in toolbarController.titleItems {
                titleItem.displayTitle = title
            }
        }
        .disposed(by: rx.disposeBag)

        output.toolbarSubtitle.driveOnNext { [weak self] subtitle in
            guard let self else { return }
            for titleItem in toolbarController.titleItems {
                titleItem.displaySubtitle = subtitle
            }
        }
        .disposed(by: rx.disposeBag)

        output.activityStyle.driveOnNext { [weak self] activityStyle in
            guard let self else { return }
            toolbarController.apply(activityStyle: activityStyle)
        }
        .disposed(by: rx.disposeBag)

        output.activity.driveOnNext { [weak self] state in
            guard let self else { return }
            // Both displays take every state, the ones off screen without animating, so a change of
            // style shows the activity where it stands. The classic toolbar shows neither.
            let activityStyle = toolbarController.activityStyle
            toolbarController.activityItem.activityView.apply(state, animated: activityStyle == .capsule)
            toolbarController.activityTitleItem.applyActivity(state, animated: activityStyle == .windowTitle)
        }
        .disposed(by: rx.disposeBag)

        output.toolbarIcon.driveOnNext { [weak self] icon in
            guard let self else { return }
            toolbarController.activityTitleItem.displayImage = icon
        }
        .disposed(by: rx.disposeBag)

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

        // The tooltip goes on the button, not on the toolbar item: the item carries a
        // custom view, and AppKit does not forward `NSToolbarItem.toolTip` to one. A
        // disabled button still shows it, which is the whole arrangement — the reason the
        // action is unavailable has to be readable without clicking.
        output.attachAvailability.driveOnNext { [weak self] availability in
            guard let self else { return }
            toolbarController.attachItem.button.isEnabled = availability.isEnabled
            toolbarController.attachItem.button.toolTip = availability.explanation
        }
        .disposed(by: rx.disposeBag)

        output.isSidebarBackHidden.drive(toolbarController.sidebarBackItem.rx.isHidden).disposed(by: rx.disposeBag)

        output.isNavigationHidden.drive(toolbarController.navigationItem.rx.isHidden).disposed(by: rx.disposeBag)

        output.canGoPrevious.drive(toolbarController.navigationItem.segmentedControl.rx.enabledForSegment(at: 0)).disposed(by: rx.disposeBag)

        output.canGoNext.drive(toolbarController.navigationItem.segmentedControl.rx.enabledForSegment(at: 1)).disposed(by: rx.disposeBag)

        // Row content first, reachability second: `attachHistoryMenus`
        // must see menus that already match the snapshot it is judging.
        bindHistoryMenu(
            toolbarController.navigationItem.backwardHistoryMenu,
            to: output.navigationHistory.map(\.backwardItems)
        )
        .disposed(by: rx.disposeBag)

        bindHistoryMenu(
            toolbarController.navigationItem.forwardHistoryMenu,
            to: output.navigationHistory.map(\.forwardItems)
        )
        .disposed(by: rx.disposeBag)

        output.navigationHistory.driveOnNext { [weak self] snapshot in
            guard let self else { return }
            toolbarController.navigationItem.attachHistoryMenus(
                hasBackwardItems: !snapshot.backwardItems.isEmpty,
                hasForwardItems: !snapshot.forwardItems.isEmpty
            )
        }
        .disposed(by: rx.disposeBag)

        output.switchSourceState.driveOnNext { [weak self] state in
            guard let self else { return }
            for picker in toolbarController.runtimeSourcePickers {
                picker.title = state.title
                picker.icon = state.pickerIcon
            }
        }
        .disposed(by: rx.disposeBag)

        output.runtimeSourcePickerContent.driveOnNext { [weak self] content in
            guard let self else { return }
            runtimeSourcePopoverAdapter.content = content
            runtimeSourceMenuAdapter.content = content
        }
        .disposed(by: rx.disposeBag)

        // The press opens the list from the picker pressed. Like a menu, the list is the view
        // layer's; what is chosen in it goes back to the view model as input.
        for picker in toolbarController.runtimeSourcePickers {
            picker.rx.controlEvent.asSignal().emitOnNext { [weak self, weak picker] in
                guard let self, let picker else { return }
                runtimeSourcePopoverAdapter.showPopover(from: picker)
            }
            .disposed(by: rx.disposeBag)
        }

        Signal.merge(runtimeSourcePopoverAdapter.openFileRequested, runtimeSourceMenuAdapter.openFileRequested).emitOnNext {
            NSDocumentController.shared.openDocument(nil)
        }
        .disposed(by: rx.disposeBag)

        Signal.merge(runtimeSourcePopoverAdapter.dependencyCacheSettingsRequested, runtimeSourceMenuAdapter.dependencyCacheSettingsRequested).emitOnNext {
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
        }
        .disposed(by: rx.disposeBag)

        viewModel.errorRelay
            .asSignal()
            .emitOnNextMainActor { [weak self] error in
                guard let self else { return }
                NSAlert(error: error).beginSheetModal(for: contentWindow)
            }
            .disposed(by: rx.disposeBag)
    }

    /// `NSMenu.rx.items(source:)` is curried — it returns the binding
    /// function that takes the per-item configuration closure. Calling it
    /// with a trailing closure instead makes the compiler fall back to
    /// `Reactive`'s dynamic-member lookup and resolve `rx.items` as the
    /// `Binder<[NSMenuItem]>` for `NSMenu.items`, so the second call is
    /// spelled out here once rather than at both call sites.
    private func bindHistoryMenu(_ menu: NSMenu, to items: Driver<[NavigationHistoryItem]>) -> Disposable {
        menu.rx.items(source: items.asObservable())({ menuItem, item in
            menuItem.image = item.icon
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                menuItem.preferredImageVisibility = .visible
            }
            #endif
        })
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

    @objc func exportInterface(_ sender: Any?) {
        viewModel?.router.trigger(.exportInterfaces)
    }

    @objc func exportMultipleImages(_ sender: Any?) {
        viewModel?.router.trigger(.exportMultipleImages)
    }

    // MARK: - Tab Actions

    /// ⌘T: an empty tab in the focused editor pane.
    @objc func newTab(_ sender: Any?) {
        documentState.selectionRouter.trigger(.newTab)
    }

    /// ⌘W, in the order of Xcode's Close Tab, Editor Pane, Window Tab, or
    /// Window: the focused pane's active tab while the pane has another, else
    /// the focused pane while there is another, else the window. "Close
    /// Window" (⌘⇧W) always closes the window.
    @objc func closeTab(_ sender: Any?) {
        switch documentState.editorArea.closeTarget {
        case .tab(let tabID):
            documentState.selectionRouter.trigger(.closeTab(tabID))
        case .pane(let paneID):
            documentState.selectionRouter.trigger(.closeEditorPane(paneID))
        case .window:
            contentWindow.performClose(sender)
        }
    }

    /// The title of ⌘W for what `closeTab(_:)` closes now, the titles Xcode gives its item
    /// (`-[IDEWorkspaceWindow menuItemTitleForCloseEditorTabBehavior:]`); `nil` when it closes the
    /// window, which File ▸ Close Window then does under ⌘W (`TabMenuController`).
    var closeTabMenuItemTitle: String? {
        switch documentState.editorArea.closeTarget {
        case .tab:
            "Close Tab"
        case .pane:
            "Close Editor Pane"
        case .window:
            nil
        }
    }

    @objc func selectNextTab(_ sender: Any?) {
        selectTab(offsetFromActiveTab: 1)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        selectTab(offsetFromActiveTab: -1)
    }

    /// The tab `offset` places from the focused pane's active tab, wrapping around.
    private func selectTab(offsetFromActiveTab offset: Int) {
        let focusedPane = documentState.editorArea.focusedPane
        let tabCount = focusedPane.tabs.count
        guard tabCount > 1 else { return }
        let targetIndex = (focusedPane.activeTabIndex + offset + tabCount) % tabCount
        documentState.selectionRouter.trigger(.switchTab(focusedPane.tabs[targetIndex].id))
    }

    // MARK: - Editor Pane Actions

    /// ⌃⌘T, Xcode's Editor Pane On Right.
    @objc func newEditorPaneOnRight(_ sender: Any?) {
        documentState.selectionRouter.trigger(.newEditorPane(.onRight))
    }

    /// ⌃⌥⌘T, Xcode's Editor Pane Below.
    @objc func newEditorPaneBelow(_ sender: Any?) {
        documentState.selectionRouter.trigger(.newEditorPane(.below))
    }

    /// ⌃⇧⌘W.
    @objc func closeEditorPane(_ sender: Any?) {
        documentState.selectionRouter.trigger(.closeEditorPane(documentState.editorArea.focusedPaneID))
    }

    /// ⌃⌥⇧⌘W.
    @objc func closeOtherEditorPanes(_ sender: Any?) {
        documentState.selectionRouter.trigger(.closeOtherEditorPanes)
    }

    /// ⌃`: the next pane left to right and top to bottom, wrapping around.
    @objc func moveFocusToNextEditorPane(_ sender: Any?) {
        let editorArea = documentState.editorArea
        documentState.selectionRouter.trigger(.focusEditorPane(editorArea.layout.paneID(after: editorArea.focusedPaneID)))
    }

    /// ⌃⇧`.
    @objc func moveFocusToPreviousEditorPane(_ sender: Any?) {
        let editorArea = documentState.editorArea
        documentState.selectionRouter.trigger(.focusEditorPane(editorArea.layout.paneID(before: editorArea.focusedPaneID)))
    }

    @objc func changeEditorOrientation(_ sender: Any?) {
        documentState.selectionRouter.trigger(.changeEditorOrientation)
    }

    /// Only the views change, so it goes to the editor area through `MainCoordinator`, not through
    /// the document.
    @objc func resetEditorSizes(_ sender: Any?) {
        viewModel?.router.trigger(.resetEditorSizes)
    }

    // MARK: - Font Size Actions

    @objc func increaseFontSize(_ sender: Any?) {
        increaseFontSizeRelay.accept(())
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        decreaseFontSizeRelay.accept(())
    }

    @objc func resetFontSize(_ sender: Any?) {
        resetFontSizeRelay.accept(())
    }

    // MARK: - Navigate Actions

    @objc func revealInSidebarNavigator(_ sender: Any?) {
        viewModel?.router.trigger(.revealInSidebarNavigator)
    }

    /// The focused tab's object as Swift imports it, or back to its header, where the modifier
    /// keys say.
    @objc func toggleGeneratedInterface(_ sender: Any?) {
        guard let toggledEntry = documentState.editorArea.focusedPane.activeTab.currentEntry?.togglingGeneratedInterface else { return }
        let destination = SelectionRoute.Destination(listClickModifierFlags: NSEvent.modifierFlags)
        documentState.selectionRouter.trigger(.open(toggledEntry.object, in: destination, interfaceLanguage: toggledEntry.interfaceLanguage))
    }

    // MARK: - Find Actions

    @objc func showFindNavigator(_ sender: Any?) {
        viewModel?.router.trigger(.find)
    }

    @objc func findCallHierarchy(_ sender: Any?) {
        runCrossReferenceCommand(.callHierarchy)
    }

    @objc func findCallees(_ sender: Any?) {
        runCrossReferenceCommand(.callees)
    }

    @objc func findTypeReferences(_ sender: Any?) {
        runCrossReferenceCommand(.typeReferences)
    }

    private func runCrossReferenceCommand(_ mode: FindMode) {
        guard let request = documentState.crossReferenceRequest(mode) else { return }
        documentState.findSession.runCrossReferenceCommand(request)
    }

    // MARK: - Report Actions

    @objc func showReportNavigator(_ sender: Any?) {
        viewModel?.router.trigger(.reports)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        switch aSelector {
        case #selector(exportInterface(_:)):
            return documentState.currentImageNode != nil
        case #selector(revealInSidebarNavigator(_:)):
            return documentState.isSelectedRuntimeObjectInCurrentImage
        case #selector(toggleGeneratedInterface(_:)):
            return documentState.editorArea.focusedPane.activeTab.currentEntry?.togglingGeneratedInterface != nil
        case #selector(exportMultipleImages(_:)):
            return documentState.runtimeEngine.imageNodes.count >= 2
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return documentState.editorArea.focusedPane.tabs.count > 1
        case #selector(closeEditorPane(_:)), #selector(closeOtherEditorPanes(_:)),
             #selector(moveFocusToNextEditorPane(_:)), #selector(moveFocusToPreviousEditorPane(_:)),
             #selector(changeEditorOrientation(_:)), #selector(resetEditorSizes(_:)):
            // The only pane cannot be closed, has no other pane to hand the focus to, and has
            // nothing to turn or to size.
            return documentState.editorArea.panes.count > 1
        case #selector(findCallHierarchy(_:)):
            return documentState.crossReferenceRequest(.callHierarchy) != nil
        case #selector(findCallees(_:)):
            return documentState.crossReferenceRequest(.callees) != nil
        case #selector(findTypeReferences(_:)):
            return documentState.crossReferenceRequest(.typeReferences) != nil
        default:
            return super.responds(to: aSelector)
        }
    }
}

extension MainWindowController: MainToolbarController.Delegate {}

extension MainWindowController: NSMenuItemValidation {
    /// Enabling is `responds(to:)`'s; this only checks Generated Interface while the focused tab
    /// shows it.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleGeneratedInterface(_:)) {
            menuItem.state = documentState.editorArea.focusedPane.activeTab.currentEntry?.showsGeneratedInterface == true ? .on : .off
        }
        return true
    }
}

extension NSUserInterfaceItemIdentifier {
    static func makeIdentifier<T>(of type: T.Type) -> Self {
        "com.JH.RuntimeViewer.\(T.self).identifier"
    }
}
