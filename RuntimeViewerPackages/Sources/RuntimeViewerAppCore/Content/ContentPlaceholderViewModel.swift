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

    /// What shows under the Open Quickly field.
    public enum Search: Equatable {
        /// Nothing searched: the recent objects show.
        case inactive
        /// The engine's images and indexed objects are being read for the first search.
        case loading
        /// What matched, best first, and the row Return opens: the first, until the arrow keys move
        /// it; `nil` when nothing matched.
        case results([ContentStartPageItemCellViewModel], selectedIndex: Int?)
    }

    /// How many recent objects show until Show All: Xcode's initial editor's `defaultRowCount`.
    public nonisolated static let defaultRecentRowCount = 8

    /// How many characters the Open Quickly field needs before it searches: Xcode's initial editor
    /// writes a query through only from three on (`queryView(_:controlTextDidChange:)`), and leaves
    /// the previous one standing below that.
    public nonisolated static let minimumSearchTextLength = 3

    /// How many matches the field lists.
    public nonisolated static let maximumSearchResultCount = 100

    @RxObserved public private(set) var search: Search = .inactive

    /// What the engine's images and indexed objects were read into for the search under way; gone
    /// once the search ends, so nothing of it stays in memory between searches.
    private var catalogTask: Task<OpenQuicklyCatalog, Never>?

    /// Ends the search under way: the field's text goes, and so does the catalog.
    private let searchResetRelay = PublishRelay<Void>()

    /// The newest text the search took, and the text the results on show answer: the two differ
    /// while the newest text is still matching — or the catalog still being read — and Return
    /// then waits for the newest results instead of opening one of an older text.
    private var latestSearchText = ""

    private var resultsSearchText: String?

    /// Return pressed while the newest results were still coming: it opens the selected one of
    /// them as soon as they arrive.
    private var pendingSearchCommitDestination: SelectionRoute.Destination?

    private let clearSearchFieldRelay = PublishRelay<Void>()

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

    /// Starts the page over as a new one: Show All off, no search, and — the view does it — nothing
    /// selected.
    private func startOver() {
        isShowingAllRecentItems = false
        updateShownRecentItems()
        endSearch()
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

    // MARK: - Search

    /// What one search step comes to, before any row is made: rows are made on the main thread.
    private enum SearchStep {
        case inactive
        case loading
        case matched([OpenQuicklyCatalog.Entry], searchText: String)
    }

    /// Searches as the field's text changes: from `minimumSearchTextLength` characters on, against
    /// the catalog the first such text reads; an empty field — or the end of the search — clears
    /// it, and a newer text cancels the search of the one before. Shorter text never reaches the
    /// search, so the previous query goes on and its result stands, as in Xcode, whose field does
    /// not write shorter text through: dropping a search still reading the catalog would leave the
    /// page loading for good.
    private func followSearchText(_ searchText: Signal<String>) {
        let minimumSearchTextLength = Self.minimumSearchTextLength
        Observable.merge(
            searchText.asObservable(),
            searchResetRelay.asObservable().map { "" }
        )
        .filter { text in text.isEmpty || text.count >= minimumSearchTextLength }
        .do(onNext: { [weak self] text in
            self?.latestSearchText = text
        })
        .flatMapLatest { [weak self] text -> Observable<SearchStep> in
            guard let self else { return .empty() }
            if text.isEmpty {
                dropCatalog()
                return .just(.inactive)
            }
            let catalogTask = catalog()
            return Observable<SearchStep>.async {
                let catalog = await catalogTask.value
                return .matched(await Self.matches(in: catalog, for: text), searchText: text)
            }
            .withLoadingPlaceholder(
                .loading,
                appearsAfter: LoadingPlaceholderTiming.appearsAfter,
                staysAtLeast: LoadingPlaceholderTiming.staysAtLeast
            )
        }
        .observeOnMainScheduler()
        .subscribeOnNext { [weak self] step in
            guard let self else { return }
            apply(step)
        }
        .disposed(by: rx.disposeBag)
    }

    private func apply(_ step: SearchStep) {
        switch step {
        case .inactive:
            resultsSearchText = nil
            pendingSearchCommitDestination = nil
            search = .inactive
        case .loading:
            search = .loading
        case .matched(let entries, let searchText):
            let engine = documentState.runtimeEngine
            let engineName = engine.source.description
            let rows = entries.map { entry in
                ContentStartPageItemCellViewModel(item: entry.item, engineName: engineName, engineID: engine.engineID)
            }
            resultsSearchText = searchText
            search = .results(rows, selectedIndex: rows.isEmpty ? nil : 0)
            if let destination = pendingSearchCommitDestination, searchText == latestSearchText {
                pendingSearchCommitDestination = nil
                commitSearch(in: destination)
            }
        }
    }

    /// The catalog of the search under way, read on first use: the leaves of the engine's image
    /// tree, which only the main actor reads, and the objects of its indexed images.
    private func catalog() -> Task<OpenQuicklyCatalog, Never> {
        if let catalogTask { return catalogTask }
        let engine = documentState.runtimeEngine
        let imagePaths = engine.imageNodes.flatMap(\.leafImagePaths)
        let catalogTask = Task.detached {
            await OpenQuicklyCatalog.load(imagePaths: imagePaths, from: engine)
        }
        self.catalogTask = catalogTask
        return catalogTask
    }

    private func dropCatalog() {
        catalogTask?.cancel()
        catalogTask = nil
    }

    /// A page that goes away mid-search stops reading the engine's objects for it.
    deinit {
        catalogTask?.cancel()
    }

    /// Matching runs off the main thread: a catalog of every indexed image can hold hundreds of
    /// thousands of names.
    private nonisolated static func matches(in catalog: OpenQuicklyCatalog, for text: String) async -> [OpenQuicklyCatalog.Entry] {
        guard !Task.isCancelled else { return [] }
        return catalog.matches(for: text, limit: maximumSearchResultCount)
    }

    /// Moves the row Return opens by `offset`, staying within the results.
    private func moveSearchSelection(by offset: Int) {
        guard case .results(let rows, let selectedIndex?) = search else { return }
        let movedIndex = min(max(selectedIndex + offset, 0), rows.count - 1)
        guard movedIndex != selectedIndex else { return }
        search = .results(rows, selectedIndex: movedIndex)
    }

    /// Opens the selected result, if there is one, and ends the search; while the newest text's
    /// results are still coming, opens the selected one of them once they arrive.
    private func commitSearch(in destination: SelectionRoute.Destination) {
        if !latestSearchText.isEmpty, resultsSearchText != latestSearchText {
            pendingSearchCommitDestination = destination
            return
        }
        guard case .results(let rows, let selectedIndex?) = search else { return }
        let item = rows[selectedIndex].item
        endSearch()
        open(item, in: destination)
    }

    /// Ends the search: no results, no catalog, nothing waiting to open, and the field emptied.
    private func endSearch() {
        pendingSearchCommitDestination = nil
        searchResetRelay.accept(())
        clearSearchFieldRelay.accept(())
    }

    // MARK: - Opening

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
        /// The Open Quickly field's text, at every change.
        @Init(default: Signal<String>.empty())
        public let searchText: Signal<String>
        /// The up (−1) and down (+1) arrow keys in the field: the row Return opens moves.
        @Init(default: Signal<Int>.empty())
        public let searchSelectionMoved: Signal<Int>
        /// Return in the field, with where the modifier keys send the selected result.
        @Init(default: Signal<SelectionRoute.Destination>.empty())
        public let searchCommitted: Signal<SelectionRoute.Destination>
        /// A click on a result.
        @Init(default: Signal<ItemOpening>.empty())
        public let searchResultOpened: Signal<ItemOpening>
        /// Escape in the field.
        @Init(default: Signal<Void>.empty())
        public let searchCancelled: Signal<Void>
    }

    public struct Output {
        public let placeholder: Driver<Placeholder>
        public let recentItems: Driver<[ContentStartPageItemCellViewModel]>
        public let showAllButton: Driver<ShowAllButton>
        /// The page started over: the view selects nothing.
        public let startedOver: Signal<Void>
        public let search: Driver<Search>
        /// The field's text has to go: the search ended.
        public let clearSearchField: Signal<Void>
    }

    public func transform(_ input: Input) -> Output {
        input.pageWillAppear.emitOnNext { [weak self] in
            guard let self else { return }
            startOver()
        }
        .disposed(by: rx.disposeBag)

        followSearchText(input.searchText)

        input.searchSelectionMoved.emitOnNext { [weak self] offset in
            guard let self else { return }
            moveSearchSelection(by: offset)
        }
        .disposed(by: rx.disposeBag)

        input.searchCommitted.emitOnNext { [weak self] destination in
            guard let self else { return }
            commitSearch(in: destination)
        }
        .disposed(by: rx.disposeBag)

        input.searchResultOpened.emitOnNext { [weak self] opening in
            guard let self else { return }
            endSearch()
            open(opening.item.item, in: opening.destination)
        }
        .disposed(by: rx.disposeBag)

        input.searchCancelled.emitOnNext { [weak self] in
            guard let self else { return }
            endSearch()
        }
        .disposed(by: rx.disposeBag)

        // A window moved to another engine searches that engine's images: the search under way
        // ends.
        documentState.$runtimeEngineSession.asObservable()
            .map(\.engine)
            .distinctUntilChanged { $0 === $1 }
            .skip(1)
            .observeOnMainScheduler()
            .subscribeOnNext { [weak self] _ in
                guard let self else { return }
                endSearch()
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
            startedOver: startedOverRelay.asSignal(),
            search: $search.asDriver(),
            clearSearchField: clearSearchFieldRelay.asSignal()
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
