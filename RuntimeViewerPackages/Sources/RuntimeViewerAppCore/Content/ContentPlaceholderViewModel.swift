import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

/// What the content pane shows while it has no object: the start page — Xcode's
/// initial editor, an Open Quickly field and the engine's recent objects
/// (proposal `editor-start-page`) — or, while the file service is still
/// reading the window's file, that it is. A window opens on a file the moment
/// the user opens it, and a dyld shared cache keeps the service busy for a
/// while; without this the window would sit empty with no sign that anything
/// is happening.
public final class ContentPlaceholderViewModel: ViewModel<ContentRoute> {
    public enum Placeholder: Equatable {
        /// Nothing is selected: the start page.
        case noSelection
        /// The window's file is being read, named as the runtime source
        /// picker names it.
        case readingFile(named: String)
    }

    @RxObserved public private(set) var placeholder: Placeholder = .noSelection

    /// The button at the end of the Recent Objects header, after Xcode's initial editor: none
    /// while every recent object shows, otherwise Show All, which becomes Show Less.
    public enum ShowAllButton: Equatable, Sendable {
        case hidden
        case showAll
        case showLess

        public var title: String? {
            switch self {
            case .hidden: nil
            case .showAll: "Show All"
            case .showLess: "Show Less"
            }
        }
    }

    /// A row opened — double-clicked, or Return on it — and where it goes.
    public struct ItemOpening {
        public let item: ContentStartPageItemCellViewModel
        public let destination: SelectionRoute.Destination

        public init(item: ContentStartPageItemCellViewModel, destination: SelectionRoute.Destination) {
            self.item = item
            self.destination = destination
        }
    }

    /// How many recent objects show until Show All: Xcode's initial editor's `defaultRowCount`.
    public static let defaultRecentRowCount = 8

    /// The recent objects the start page shows, most recent first: the first
    /// `defaultRecentRowCount` until Show All.
    @RxObserved public private(set) var recentItems: [ContentStartPageItemCellViewModel] = []

    @RxObserved public private(set) var showAllButton: ShowAllButton = .hidden

    /// Every recent object of the engine, most recent first.
    private var allRecentItems: [ContentStartPageItemCellViewModel] = []

    /// Whether Show All is on. It stays on while the list changes, as Xcode's `@State` does, and
    /// goes off whenever the page starts over (`startOver()`).
    private var isShowingAllRecentItems = false

    private let startedOverRelay = PublishRelay<Void>()

    /// The editor pane the page is in; the focused pane when `nil`. What the page opens, it opens
    /// from here: the pane takes the focus first.
    private let editorPaneID: EditorPane.ID?

    /// - Parameters:
    ///   - editorPaneID: the editor pane showing the page; the focused pane when `nil`, which is
    ///     what a test that has a single pane passes.
    public init(documentState: DocumentState, router: any Router<ContentRoute>, editorPaneID: EditorPane.ID? = nil) {
        self.editorPaneID = editorPaneID
        super.init(documentState: documentState, router: router)
        documentState.$runtimeEngineSession.asObservable()
            .map(\.engine)
            .flatMapLatest { engine in
                Self.placeholders(for: engine)
            }
            .distinctUntilChanged()
            .observeOnMainScheduler()
            .bind(to: $placeholder)
            .disposed(by: rx.disposeBag)
        followRecentObjects()
        followTheTabShown()
    }

    /// Starts the page over whenever another tab comes forward in its pane: a pane keeps one page
    /// for all its empty tabs, and going from one empty tab to another changes nothing the pane's
    /// content sees, while Xcode makes a new page for every empty editor.
    private func followTheTabShown() {
        documentState.$editorArea.asObservable()
            .map { [editorPaneID] editorArea in
                (editorPaneID.flatMap { editorArea[$0] } ?? editorArea.focusedPane).activeTabID
            }
            .distinctUntilChanged()
            .skip(1)
            .subscribeOnNext { [weak self] _ in
                guard let self else { return }
                startOver()
            }
            .disposed(by: rx.disposeBag)
    }

    /// Starts the page over as a new one: Show All off, and — the view does it — nothing selected.
    private func startOver() {
        isShowingAllRecentItems = false
        updateShownRecentItems()
        startedOverRelay.accept(())
    }

    /// Lists the recent objects of the window's engine — read again when the window moves to
    /// another engine — as they are now, and again whenever any window on the engine records one
    /// (`RecentRuntimeObjectsRecorder`). A record on another engine changes nothing here: the store
    /// holds every engine's list, and only this engine's is compared.
    private func followRecentObjects() {
        let recentObjectsByEngine = appDefaults.$recentRuntimeObjectsByEngine
        documentState.$runtimeEngineSession.asObservable()
            .map(\.engine)
            .distinctUntilChanged { $0 === $1 }
            .flatMapLatest { engine in
                recentObjectsByEngine
                    .map { objectsByEngine in RecentRuntimeObjects(engine: engine).objects(in: objectsByEngine) }
                    .distinctUntilChanged(RecentRuntimeObjects.listsAreAlike)
                    .map { recentObjects in (engine, recentObjects) }
            }
            .observeOnMainScheduler()
            .subscribeOnNext { [weak self] engine, recentObjects in
                guard let self else { return }
                let engineName = engine.source.description
                allRecentItems = recentObjects.map { object in
                    ContentStartPageItemCellViewModel(item: .object(object), engineName: engineName, engineID: engine.engineID)
                }
                updateShownRecentItems()
            }
            .disposed(by: rx.disposeBag)
    }

    /// Shows the recent objects Show All lets through, and the button that says which.
    private func updateShownRecentItems() {
        let canShowMore = allRecentItems.count > Self.defaultRecentRowCount
        let shownItems = canShowMore && !isShowingAllRecentItems ? Array(allRecentItems.prefix(Self.defaultRecentRowCount)) : allRecentItems
        if shownItems != recentItems {
            recentItems = shownItems
        }
        let button: ShowAllButton = canShowMore ? (isShowingAllRecentItems ? .showLess : .showAll) : .hidden
        if button != showAllButton {
            showAllButton = button
        }
    }

    /// Opens `item` from this page: the page's pane takes the focus first, so the focused tab, a
    /// new tab and the next pane are all reckoned from here, whichever pane had it before.
    private func open(_ item: ContentStartPageItemCellViewModel.Item, in destination: SelectionRoute.Destination) {
        let selectionRouter = documentState.selectionRouter
        if let editorPaneID {
            selectionRouter.trigger(.focusEditorPane(editorPaneID))
        }
        switch item {
        case .object(let object):
            selectionRouter.trigger(.open(formOnScreen(of: object), in: destination))
        case .image(let path):
            selectionRouter.trigger(.openImage(path, in: destination))
        }
    }

    /// `object` in the form a tab of the window shows it, in whatever language, when one does —
    /// looked for in the order `EditorArea.tabID(showing:)` looks, the focused pane first and each
    /// pane's active tab before its others: a recent object is kept without its children
    /// (`RecentRuntimeObjects.listedForm(of:)`), and opening that form where a tab shows the object
    /// with its specializations would put the bare form in its place.
    private func formOnScreen(of object: RuntimeObject) -> RuntimeObject {
        let editorArea = documentState.editorArea
        let otherPanes = editorArea.orderedPanes.filter { $0.id != editorArea.focusedPaneID }
        for pane in [editorArea.focusedPane] + otherPanes {
            let otherTabs = pane.tabs.filter { $0.id != pane.activeTabID }
            if let shownObject = ([pane.activeTab] + otherTabs).lazy.compactMap(\.object).first(where: { $0 == object }) {
                return shownObject
            }
        }
        return object
    }

    @MemberwiseInit(.public)
    public struct Input {
        /// The page is about to come back into its pane, and starts over as a new one would.
        @Init(default: Signal<Void>.empty())
        public let pageWillAppear: Signal<Void>
        /// The Recent Objects header's Show All / Show Less button.
        @Init(default: Signal<Void>.empty())
        public let showAllClicked: Signal<Void>
        /// A recent object opened, and where.
        @Init(default: Signal<ItemOpening>.empty())
        public let recentItemOpened: Signal<ItemOpening>
    }

    public struct Output {
        public let placeholder: Driver<Placeholder>
        public let recentItems: Driver<[ContentStartPageItemCellViewModel]>
        public let showAllButton: Driver<ShowAllButton>
        /// The page started over: the view selects nothing.
        public let startedOver: Signal<Void>
    }

    public func transform(_ input: Input) -> Output {
        input.pageWillAppear.emitOnNext { [weak self] in
            guard let self else { return }
            startOver()
        }
        .disposed(by: rx.disposeBag)

        input.showAllClicked.emitOnNext { [weak self] in
            guard let self else { return }
            isShowingAllRecentItems.toggle()
            updateShownRecentItems()
        }
        .disposed(by: rx.disposeBag)

        input.recentItemOpened.emitOnNext { [weak self] opening in
            guard let self else { return }
            open(opening.item.item, in: opening.destination)
        }
        .disposed(by: rx.disposeBag)

        return Output(
            placeholder: $placeholder.asDriver(),
            recentItems: $recentItems.asDriver(),
            showAllButton: $showAllButton.asDriver(),
            startedOver: startedOverRelay.asSignal()
        )
    }

    /// `.readingFile` while `engine` reads a file and has not connected to
    /// the process reading it — the first read, and every later one after a
    /// suspension or a new dependency cache — and `.noSelection` otherwise.
    /// A read is a piece of work like any other the panes wait for, so it
    /// shows through the shared loading timing: one that finishes quickly
    /// shows no placeholder, and one that shows it keeps it up long enough
    /// not to blink.
    static func placeholders(for engine: RuntimeEngine) -> Observable<Placeholder> {
        guard case .file(let name, _) = engine.source else { return .just(.noSelection) }
        let isReading = engine.statePublisher.asObservable()
            .map { state in state == .initializing || state == .connecting }
            .distinctUntilChanged()
            .observeOnMainScheduler()
            .share(replay: 1)
        // One read at a time, each to its end — its placeholder's minimum
        // time included — so the end of one read never lands on the next.
        return isReading.concatMap { reading -> Observable<Placeholder> in
            guard reading else { return .just(.noSelection) }
            let readingEnded = isReading
                .filter { !$0 }
                .take(1)
                .map { _ in Placeholder.noSelection }
            return readingEnded.withLoadingPlaceholder(
                .readingFile(named: name),
                appearsAfter: LoadingPlaceholderTiming.appearsAfter,
                staysAtLeast: LoadingPlaceholderTiming.staysAtLeast
            )
        }
    }
}
