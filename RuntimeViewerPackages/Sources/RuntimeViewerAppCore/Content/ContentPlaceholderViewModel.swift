import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

/// What the content pane shows while it has no object: the start page — Xcode's
/// initial editor, an Open Quickly field over the engine's recent images, or the
/// recent objects of the image the sidebar is in (proposal `editor-start-page`) —
/// or, while the file service is still
/// reading the window's file, that it is. A window opens on a file the moment
/// the user opens it, and a dyld shared cache keeps the service busy for a
/// while; without this the window would sit empty with no sign that anything
/// is happening. While the sidebar's object list of the image it is in is
/// still loading it, the page waits for the list instead.
public final class ContentPlaceholderViewModel: ViewModel<ContentRoute> {
    public enum Placeholder: Equatable {
        /// Nothing is selected: the start page.
        case noSelection
        /// The window's file is being read, named as the runtime source
        /// picker names it.
        case readingFile(named: String)
        /// The sidebar is in an image its object list is still loading: the page shows nothing
        /// but the list's progress (`imageListLoadingProgress`), so that none of the image's
        /// recent objects opens before the list could open it.
        case waitingForImageList
    }

    /// What the page is: the window's file being read comes first, then the wait for the
    /// sidebar's object list, then the start page.
    @RxObserved public private(set) var placeholder: Placeholder = .noSelection

    /// What the window's file being read makes the page (`placeholders(for:)`): `.readingFile`
    /// while it is read, `.noSelection` otherwise.
    private var filePlaceholder: Placeholder = .noSelection

    /// The button at the end of the recent list's header, after Xcode's initial editor: none
    /// while every recent item shows, otherwise Show All, which becomes Show Less.
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

    /// What shows under the Open Quickly field.
    public enum Search: Equatable {
        /// Nothing searched: the recent items show.
        case inactive
        /// The engine's images and indexed objects are being read for the first search.
        case loading
        /// What matched, best first, and the row Return opens: the first, until the arrow keys move
        /// it; `nil` when nothing matched.
        case results([ContentStartPageItemCellViewModel], selectedIndex: Int?)
    }

    /// How many recent items show until Show All: Xcode's initial editor's `defaultRowCount`.
    public nonisolated static let defaultRecentRowCount = 8

    /// How many characters the Open Quickly field needs before it searches: Xcode's initial editor
    /// writes a query through only from three on (`queryView(_:controlTextDidChange:)`), and leaves
    /// the previous one standing below that.
    public nonisolated static let minimumSearchTextLength = 3

    /// How many matches the field lists.
    public nonisolated static let maximumSearchResultCount = 100

    @RxObserved public private(set) var search: Search = .inactive

    /// The search the field runs, shared in shape with File › Open Quickly…'s bar
    /// (`OpenQuicklyViewModel`): the engine's images and indexed objects, read once per search.
    private lazy var openQuicklySearch = OpenQuicklySearch(documentState: documentState)

    /// Ends the search under way: the field's text goes, and so does the catalog.
    private let searchResetRelay = PublishRelay<Void>()

    /// The newest text the search took, and the text the results on show answer: the two differ
    /// while the newest text is still matching — or the catalog still being read — and Return
    /// then waits for the newest results instead of opening one of an older text.
    private var latestSearchText = ""

    private var resultsSearchText: String?

    /// Return pressed while the newest results were still coming, and the text it was pressed for:
    /// it opens the selected one of that text's results as soon as they arrive, and is dropped
    /// once the text changes again — the user is still typing.
    private var pendingSearchCommit: (destination: SelectionRoute.Destination, searchText: String)?

    private let clearSearchFieldRelay = PublishRelay<Void>()

    /// The recent list's title while the sidebar is at its image list.
    public nonisolated static let recentImagesTitle = "Recent Images"

    /// The recent list's title while the sidebar is in an image.
    public nonisolated static let recentObjectsTitle = "Recent Objects"

    /// What the start page lists, most recent first, following the sidebar: the engine's recent
    /// images while the sidebar is at its image list, the recent objects of the image the sidebar is
    /// in once it is in one — none while the page waits for the sidebar's object list of that image
    /// (`.waitingForImageList`). The first `defaultRecentRowCount` until Show All.
    @RxObserved public private(set) var recentItems: [ContentStartPageItemCellViewModel] = []

    /// How far the sidebar's object list of its image got, which the page shows while it waits for
    /// the list (`.waitingForImageList`).
    @RxObserved public private(set) var imageListLoadingProgress: ImageIndexingProgress = .preparing

    /// The recent list's title: `recentImagesTitle` or `recentObjectsTitle`, after the list on show.
    @RxObserved public private(set) var recentItemsTitle: String = ContentPlaceholderViewModel.recentImagesTitle

    @RxObserved public private(set) var showAllButton: ShowAllButton = .hidden

    /// Every recent item of the list the sidebar picks, most recent first.
    private var allRecentItems: [ContentStartPageItemCellViewModel] = []

    /// Whether the page waits for the sidebar's object list of the image the sidebar is in.
    private var isWaitingForImageList = false

    /// Whether Show All is on. It stays on while the list changes, as Xcode's `@State` does, and
    /// goes off whenever the page starts over (`startOver()`) or the sidebar picks another list.
    private var isShowingAllRecentItems = false

    /// The list the sidebar picks, as last listed: the engine, and the canonical path of the image
    /// the sidebar is in, `nil` at its image list.
    private var recentListSource: (engine: ObjectIdentifier, imagePath: String?)?

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
            .subscribeOnNext { [weak self] filePlaceholder in
                guard let self else { return }
                self.filePlaceholder = filePlaceholder
                updatePlaceholder()
            }
            .disposed(by: rx.disposeBag)
        followRecentItems()
        followImageListLoadingProgress()
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

    /// What a recent list holds: image paths at the sidebar's image list, objects in an image — or
    /// nothing yet in an image the sidebar's object list is still loading.
    private enum RecentList {
        case images([String])
        case objects([RuntimeObject])
        case waitingForImageList

        /// Whether two lists name the same items, objects in the same forms — which `==` on objects
        /// does not tell: it compares them by identity alone.
        static func areAlike(_ firstList: RecentList, _ secondList: RecentList) -> Bool {
            switch (firstList, secondList) {
            case (.images(let firstImagePaths), .images(let secondImagePaths)):
                firstImagePaths == secondImagePaths
            case (.objects(let firstObjects), .objects(let secondObjects)):
                RecentRuntimeImages.listsAreAlike(firstObjects, secondObjects)
            case (.waitingForImageList, .waitingForImageList):
                true
            default:
                false
            }
        }
    }

    /// Lists, from the window's engine's recent images, what the sidebar picks: the images while it
    /// is at its image list, the recent objects of the image it is in once it is in one. Read again
    /// when the sidebar moves or the window moves to another engine, and again whenever any window
    /// on the engine records something (`RecentRuntimeImagesRecorder`). A record on another engine
    /// changes nothing here: the store holds every engine's list, and only this engine's is
    /// compared. The sidebar's path is compared in the engine's canonical form, the form the store
    /// keeps, worked out afresh at every change of the store: the engine learns that form only after
    /// it connects, and nothing announces when it has, so the list catches up at the next record.
    /// In an image, the recent objects wait for the sidebar's object list of the image
    /// (`waitsForImageList(ofImageAt:in:)`).
    private func followRecentItems() {
        let recentImagesByEngine = appDefaults.$recentRuntimeImagesByEngine
        Observable.combineLatest(
            documentState.$runtimeEngineSession.asObservable()
                .map(\.engine)
                .distinctUntilChanged { $0 === $1 },
            documentState.$currentImageNode.asObservable()
                .map { $0?.path }
                .distinctUntilChanged()
        )
        .flatMapLatest { [documentState] engine, sidebarImagePath in
            let recentImages = RecentRuntimeImages(engine: engine)
            let recentLists: Observable<(String?, RecentList)>
            if let sidebarImagePath {
                let recentObjects = recentImagesByEngine
                    .map { imagesByEngine -> (String?, RecentList) in
                        let canonicalImagePath = engine.canonicalImagePath(sidebarImagePath)
                        return (canonicalImagePath, .objects(recentImages.objects(ofImageAt: canonicalImagePath, in: imagesByEngine)))
                    }
                recentLists = Observable.combineLatest(recentObjects, Self.waitsForImageList(ofImageAt: sidebarImagePath, in: documentState))
                    .map { recentObjects, waitsForImageList in
                        waitsForImageList ? (recentObjects.0, .waitingForImageList) : recentObjects
                    }
            } else {
                recentLists = recentImagesByEngine
                    .map { imagesByEngine -> (String?, RecentList) in
                        (nil, .images(recentImages.images(in: imagesByEngine).map(\.imagePath)))
                    }
            }
            return recentLists
                .distinctUntilChanged { $0.0 == $1.0 && RecentList.areAlike($0.1, $1.1) }
                .map { canonicalImagePath, recentList in (engine, canonicalImagePath, recentList) }
        }
        .observeOnMainScheduler()
        .subscribeOnNext { [weak self] engine, imagePath, recentList in
            guard let self else { return }
            let source = (engine: ObjectIdentifier(engine), imagePath: imagePath)
            if let recentListSource, recentListSource != source {
                isShowingAllRecentItems = false
            }
            recentListSource = source
            let engineName = engine.source.description
            isWaitingForImageList = false
            switch recentList {
            case .images(let imagePaths):
                allRecentItems = imagePaths.map { imagePath in
                    ContentStartPageItemCellViewModel(item: .image(path: imagePath), engineName: engineName, engineID: engine.engineID)
                }
            case .objects(let objects):
                allRecentItems = objects.map { object in
                    ContentStartPageItemCellViewModel(item: .object(object), engineName: engineName, engineID: engine.engineID)
                }
            case .waitingForImageList:
                allRecentItems = []
                isWaitingForImageList = true
            }
            let title = imagePath == nil ? Self.recentImagesTitle : Self.recentObjectsTitle
            if title != recentItemsTitle {
                recentItemsTitle = title
            }
            // The list before the page: a wait that ends shows the page with its list in place.
            updateShownRecentItems()
            updatePlaceholder()
        }
        .disposed(by: rx.disposeBag)
    }

    /// Shows the recent items Show All lets through, and the button that says which.
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

    /// Shows what the page is: the window's file being read, the wait for the sidebar's object
    /// list, or the start page, in that order.
    private func updatePlaceholder() {
        let shownPlaceholder: Placeholder = if filePlaceholder != .noSelection {
            filePlaceholder
        } else if isWaitingForImageList {
            .waitingForImageList
        } else {
            .noSelection
        }
        if shownPlaceholder != placeholder {
            placeholder = shownPlaceholder
        }
    }

    /// Whether the page waits for the sidebar's object list of the image at `imagePath`, in place
    /// of the image's recent objects: `true` while the list has not settled (`DocumentState.sidebarImageListLoad`), through the
    /// shared loading timing, one wait at a time, each to its end — a list that loads quickly makes
    /// the page wait without showing it, and a wait that shows stays up long enough not to blink.
    /// Until the first answer comes nothing does, so what the page showed stays until then. A
    /// report on another image, or none, is no wait.
    static func waitsForImageList(ofImageAt imagePath: String, in documentState: DocumentState) -> Observable<Bool> {
        let isListLoading = documentState.$sidebarImageListLoad.asObservable()
            .map { load -> Bool in
                guard let load, load.imagePath == imagePath else { return false }
                return !load.phase.isSettled
            }
            .distinctUntilChanged()
            .share(replay: 1)
        return isListLoading
            .concatMap { isLoading -> Observable<Bool> in
                guard isLoading else { return .just(false) }
                return isListLoading
                    .filter { !$0 }
                    .take(1)
                    .withLoadingPlaceholder(
                        true,
                        appearsAfter: LoadingPlaceholderTiming.appearsAfter,
                        staysAtLeast: LoadingPlaceholderTiming.staysAtLeast
                    )
            }
            .distinctUntilChanged()
    }

    /// Keeps `imageListLoadingProgress` at the progress the sidebar's object list reports.
    private func followImageListLoadingProgress() {
        documentState.$sidebarImageListLoad.asObservable()
            .map { $0?.phase.indexingProgress ?? .preparing }
            .distinctUntilChanged()
            .bind(to: $imageListLoadingProgress)
            .disposed(by: rx.disposeBag)
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
            guard let self else { return }
            latestSearchText = text
            if let pendingSearchCommit, pendingSearchCommit.searchText != text {
                self.pendingSearchCommit = nil
            }
        })
        .flatMapLatest { [weak self] text -> Observable<SearchStep> in
            guard let self else { return .empty() }
            if text.isEmpty {
                openQuicklySearch.end()
                return .just(.inactive)
            }
            let openQuicklySearch = openQuicklySearch
            let maximumSearchResultCount = Self.maximumSearchResultCount
            return Observable<SearchStep>.async {
                .matched(await openQuicklySearch.matches(for: text, limit: maximumSearchResultCount), searchText: text)
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
            pendingSearchCommit = nil
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
            if let pendingSearchCommit, pendingSearchCommit.searchText == searchText, searchText == latestSearchText {
                self.pendingSearchCommit = nil
                commitSearch(in: pendingSearchCommit.destination)
            }
        }
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
            pendingSearchCommit = (destination, latestSearchText)
            return
        }
        guard case .results(let rows, let selectedIndex?) = search else { return }
        let item = rows[selectedIndex].item
        endSearch()
        open(item, in: destination)
    }

    /// Ends the search: no results, no catalog, nothing waiting to open, and the field emptied.
    private func endSearch() {
        pendingSearchCommit = nil
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
            selectionRouter.trigger(.open(documentState.editorArea.shownForm(of: object) ?? object, in: destination))
        case .image(let path):
            selectionRouter.trigger(.openImage(path, in: destination))
        }
    }


    @MemberwiseInit(.public)
    public struct Input {
        /// The page is about to come back into its pane, and starts over as a new one would.
        @Init(default: Signal<Void>.empty())
        public let pageWillAppear: Signal<Void>
        /// The recent list header's Show All / Show Less button.
        @Init(default: Signal<Void>.empty())
        public let showAllClicked: Signal<Void>
        /// A recent item opened, and where.
        @Init(default: Signal<ContentStartPageItemOpening>.empty())
        public let recentItemOpened: Signal<ContentStartPageItemOpening>
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
        @Init(default: Signal<ContentStartPageItemOpening>.empty())
        public let searchResultOpened: Signal<ContentStartPageItemOpening>
        /// Escape in the field.
        @Init(default: Signal<Void>.empty())
        public let searchCancelled: Signal<Void>
    }

    public struct Output {
        public let placeholder: Driver<Placeholder>
        public let recentItems: Driver<[ContentStartPageItemCellViewModel]>
        /// How far the sidebar's object list got, for the progress shown while the page waits for
        /// it (`.waitingForImageList`).
        public let imageListLoadingProgress: Driver<ImageIndexingProgress>
        public let recentItemsTitle: Driver<String>
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
            imageListLoadingProgress: $imageListLoadingProgress.asDriver(),
            recentItemsTitle: $recentItemsTitle.asDriver(),
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
