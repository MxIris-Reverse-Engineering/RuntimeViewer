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

    private(set) lazy var tabBarAccessoryController = TabBarAccessoryController(nibName: nil, bundle: nil)

    private(set) lazy var splitViewController = MainSplitViewController()

    private var viewModel: MainViewModel?

    private let frameworksSelectedRelay = PublishRelay<[URL]>()

    private let saveLocationSelectedRelay = PublishRelay<URL>()

    private let dependencyCacheSelectedRelay = PublishRelay<RuntimeOfflineFile.DependencyCache?>()

    /// The engine the engine menu has selected, so a menu command that is not
    /// an engine can put the selection back.
    private var selectedEngineIdentifierInMenu: String?

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
        contentWindow.addTitlebarAccessoryViewController(tabBarAccessoryController)
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
            switchSource: toolbarController.switchSourceItem.popUpButton.rx.selectedItemRepresentedObject(String.self).asSignal(),
            generationOptionsClick: toolbarController.generationOptionsItem.button.rx.click.asSignal(),
            increaseFontSize: increaseFontSizeRelay.asSignal(),
            decreaseFontSize: decreaseFontSizeRelay.asSignal(),
            resetFontSize: resetFontSizeRelay.asSignal(),
            loadFrameworksClick: toolbarController.loadFrameworksItem.button.rx.click.asSignal(),
            attachToProcessClick: toolbarController.attachItem.button.rx.click.asSignal(),
            mcpStatusClick: toolbarController.mcpStatusItem.button.rx.click.asSignal(),
            activityClick: Signal.merge(
                toolbarController.activityItem.activityView.rx.controlEvent.asSignal(),
                toolbarController.titleItem.activityIndicator?.rx.controlEvent.asSignal() ?? .empty()
            ),
            frameworksSelected: frameworksSelectedRelay.asSignal(),
            saveLocationSelected: saveLocationSelectedRelay.asSignal(),
            tabSelected: tabBarAccessoryController.tabSelectedRelay.asSignal(),
            tabClosed: tabBarAccessoryController.tabClosedRelay.asSignal(),
            newTabClicked: tabBarAccessoryController.newTabClicked,
            dependencyCacheSelected: dependencyCacheSelectedRelay.asSignal()
        )
        let output = viewModel.transform(input)

        output.isLoadFrameworksEnabled.drive(toolbarController.loadFrameworksItem.button.rx.isEnabled).disposed(by: rx.disposeBag)

        output.tabBarSnapshot.driveOnNext { [weak self] snapshot in
            guard let self else { return }
            tabBarAccessoryController.applySnapshot(snapshot)
        }
        .disposed(by: rx.disposeBag)

        output.isTabBarHidden.driveOnNext { [weak self] isHidden in
            guard let self else { return }
            tabBarAccessoryController.isHidden = isHidden
        }
        .disposed(by: rx.disposeBag)

        output.windowTitle.driveOnNext { [weak self] title in
            guard let self else { return }
            contentWindow.title = title
        }
        .disposed(by: rx.disposeBag)

        output.toolbarTitle.driveOnNext { [weak self] title in
            guard let self else { return }
            toolbarController.titleItem.displayTitle = title
        }
        .disposed(by: rx.disposeBag)

        output.toolbarSubtitle.driveOnNext { [weak self] subtitle in
            guard let self else { return }
            toolbarController.titleItem.displaySubtitle = subtitle
        }
        .disposed(by: rx.disposeBag)

        output.activity.driveOnNext { [weak self] state in
            guard let self else { return }
            if MainToolbarController.showsActivityCapsule {
                toolbarController.activityItem.activityView.apply(state, animated: true)
            } else {
                toolbarController.titleItem.applyActivity(state, animated: true)
            }
        }
        .disposed(by: rx.disposeBag)

        if !MainToolbarController.showsActivityCapsule {
            output.toolbarIcon.driveOnNext { [weak self] icon in
                guard let self else { return }
                toolbarController.titleItem.displayImage = icon
            }
            .disposed(by: rx.disposeBag)
        }

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

        // Bind menu content + selection from sections and switchSourceState
        Driver.combineLatest(output.runtimeEngineSections, output.switchSourceState, output.dependencyCacheChoices)
            .driveOnNext { [weak self] sections, state, dependencyCacheChoices in
                guard let self else { return }
                let popUpButton = toolbarController.switchSourceItem.popUpButton
                selectedEngineIdentifierInMenu = state.selectedEngineIdentifier

                popUpButton.menu?.removeAllItems()

                // Build menu from sections
                for (sectionIndex, section) in sections.enumerated() {
                    if sectionIndex > 0 {
                        popUpButton.menu?.addItem(.separator())
                    }
                    let header = NSMenuItem.sectionHeader(title: section.hostName)
                    popUpButton.menu?.addItem(header)

                    for engine in section.engines {
                        let menuItem = NSMenuItem(title: engine.source.description, action: nil, keyEquivalent: "")
                        menuItem.image = self.viewModel?.resolveEngineIcon(for: engine)
                        menuItem.image?.size = NSSize(width: 20, height: 20)
                        menuItem.representedObject = AnyHashable(engine.engineID)
                        popUpButton.menu?.addItem(menuItem)
                    }

                    if section.hostID == RuntimeHostInfo.offlineFiles.hostID {
                        for menuItem in makeOfflineFileMenuItems(dependencyCacheChoices: dependencyCacheChoices) {
                            popUpButton.menu?.addItem(menuItem)
                        }
                    }
                }

                // Update selection based on connection state
                if state.isDisconnected {
                    // Insert a disabled placeholder for the disconnected engine
                    let placeholder = NSMenuItem(title: state.title, action: nil, keyEquivalent: "")
                    placeholder.image = state.image
                    placeholder.image?.size = NSSize(width: 20, height: 20)
                    placeholder.isEnabled = false
                    popUpButton.menu?.insertItem(placeholder, at: 0)
                    popUpButton.menu?.insertItem(.separator(), at: 1)
                    popUpButton.select(placeholder)
                } else {
                    // Select the matching engine
                    let matchingIndex = popUpButton.menu?.items.firstIndex {
                        ($0.representedObject as? AnyHashable) == AnyHashable(state.selectedEngineIdentifier)
                    }
                    if let matchingIndex {
                        popUpButton.selectItem(at: matchingIndex)
                    }
                }
            }.disposed(by: rx.disposeBag)

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

    @objc func newTab(_ sender: Any?) {
        documentState.selectionRouter.trigger(.newTab)
    }

    /// ⌘W: close the active tab, or fall back to closing the window when it is
    /// the only tab (Safari behaviour). "Close Window" (⌘⇧W) always closes the
    /// window.
    @objc func closeTab(_ sender: Any?) {
        if documentState.tabs.count > 1 {
            documentState.selectionRouter.trigger(.closeTab(index: documentState.activeTabIndex))
        } else {
            contentWindow.performClose(sender)
        }
    }

    @objc func selectNextTab(_ sender: Any?) {
        let tabCount = documentState.tabs.count
        guard tabCount > 1 else { return }
        let nextIndex = (documentState.activeTabIndex + 1) % tabCount
        documentState.selectionRouter.trigger(.switchTab(index: nextIndex))
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        let tabCount = documentState.tabs.count
        guard tabCount > 1 else { return }
        let previousIndex = (documentState.activeTabIndex - 1 + tabCount) % tabCount
        documentState.selectionRouter.trigger(.switchTab(index: previousIndex))
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
        case #selector(exportMultipleImages(_:)):
            return documentState.runtimeEngine.imageNodes.count >= 2
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return documentState.tabs.count > 1
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

    // MARK: - Offline files in the engine menu

    /// The Offline Files section's last entries: Open File…, and the
    /// Dependency Cache submenu when the window is on an offline engine that
    /// reads one.
    private func makeOfflineFileMenuItems(dependencyCacheChoices: [OfflineFileController.DependencyCacheChoice]) -> [NSMenuItem] {
        var menuItems: [NSMenuItem] = []
        let openFileItem = NSMenuItem(title: "Open File…", action: #selector(openOfflineFileFromEngineMenu(_:)), keyEquivalent: "")
        openFileItem.target = self
        menuItems.append(openFileItem)

        guard !dependencyCacheChoices.isEmpty else { return menuItems }
        let submenu = NSMenu(title: "Dependency Cache")
        for choice in dependencyCacheChoices {
            let choiceItem = NSMenuItem(title: choice.title, action: #selector(dependencyCacheChosenFromEngineMenu(_:)), keyEquivalent: "")
            choiceItem.target = self
            choiceItem.state = choice.isCurrent ? .on : .off
            choiceItem.representedObject = DependencyCacheMenuChoice(dependencyCache: choice.dependencyCache)
            submenu.addItem(choiceItem)
        }
        submenu.addItem(.separator())
        submenu.addItem(NSMenuItem(title: "Manage in Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ""))
        let dependencyCacheItem = NSMenuItem(title: "Dependency Cache", action: nil, keyEquivalent: "")
        dependencyCacheItem.submenu = submenu
        menuItems.append(dependencyCacheItem)
        return menuItems
    }

    @objc private func openOfflineFileFromEngineMenu(_ sender: NSMenuItem) {
        restoreEngineMenuSelection()
        NSDocumentController.shared.openDocument(sender)
    }

    @objc private func dependencyCacheChosenFromEngineMenu(_ sender: NSMenuItem) {
        restoreEngineMenuSelection()
        guard let choice = sender.representedObject as? DependencyCacheMenuChoice else { return }
        dependencyCacheSelectedRelay.accept(choice.dependencyCache)
    }

    /// A command in the engine menu is no engine to show: the pop-up goes
    /// back to the engine it had.
    private func restoreEngineMenuSelection() {
        let popUpButton = toolbarController.switchSourceItem.popUpButton
        guard let selectedEngineIdentifierInMenu,
              let index = popUpButton.menu?.items.firstIndex(where: { ($0.representedObject as? AnyHashable) == AnyHashable(selectedEngineIdentifierInMenu) })
        else { return }
        popUpButton.selectItem(at: index)
    }
}

extension MainWindowController: MainToolbarController.Delegate {}

extension NSUserInterfaceItemIdentifier {
    static func makeIdentifier<T>(of type: T.Type) -> Self {
        "com.JH.RuntimeViewer.\(T.self).identifier"
    }
}

/// The represented object of a Dependency Cache menu item: an optional does
/// not survive the trip through `Any`.
private final class DependencyCacheMenuChoice {
    let dependencyCache: RuntimeOfflineFile.DependencyCache?

    init(dependencyCache: RuntimeOfflineFile.DependencyCache?) {
        self.dependencyCache = dependencyCache
    }
}
