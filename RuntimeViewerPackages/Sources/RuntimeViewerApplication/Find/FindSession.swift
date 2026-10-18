import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerCrossReferences
import RuntimeViewerArchitectures
import RuntimeViewerSettings

/// The Find navigator's state for one document: the query in force, the
/// results it produced, and the search running to produce them.
///
/// Owned by `DocumentState`, not by a ViewModel, because the navigator's
/// page exists twice — once in each level of the sidebar — and both show the
/// same search. A `FindViewModel` per page binds to this; the session
/// outlives either page and needs no router.
///
/// Searches are engine requests: text and member searches stream their
/// matches in per-image batches, which land here as results grow, so the
/// outline fills while the engine is still scanning; relationship searches
/// answer in one piece. A new search cancels the one in flight, and whatever
/// the cancelled one still delivers is dropped (see `SearchRun`). The results
/// belong to the process behind the document's engine: when the document
/// moves to another engine, or its engine comes back with a new process
/// behind it, the search on screen runs again
/// (`DocumentState.runtimeEngineDidReset`).
///
/// Text and member searches read the interfaces under the Generation Options
/// the content pane displays with, so they find only what it shows; when
/// those options change, the search in force runs again under the new ones.
/// A corpus built after a search ran is read by that search on its own,
/// its hits merged into the results, so the list keeps its selection and
/// scroll position while images keep becoming searchable.
///
/// The query's scope limits every kind of search to some images: the
/// sidebar's, as it is when the search runs, or the ones picked in the scope
/// chooser. A corpus built later outside the scope is not read, the summary
/// bar speaks of the corpora in scope only, and the images in scope still
/// waiting for theirs go to the front of the queue.
///
/// Call Hierarchy, Callees and Type References show a tree that loads a
/// level each time a row is first expanded (`FindCrossReferenceTree`): the
/// search finds the roots, the roots it opens load at once, and every other
/// level waits for its row. One level loads at a time, in the order the rows
/// were expanded: each is a scan of the indexed images in scope, as many at
/// once as the Max Concurrent Scans setting allows. Their scope limits where
/// callers and references are looked for — never past the indexed images —
/// and Callees reads the one function a row stands for.
@MainActor
@Loggable(.private)
public final class FindSession {
    /// The results tree and the words above it, published together so the
    /// outline and the summary bar never disagree.
    public struct Results: Equatable {
        public var nodes: [FindResultNode] = []
        /// `N results in M types`, or `nil` while there is nothing to say —
        /// the summary bar is absent then, as in Xcode. Says nothing about
        /// the corpora; `FindSession.summary` adds that.
        public var summary: String?
        /// Images the search did not see because their corpus is not built.
        public var unbuiltImagePaths: [String] = []
        public var isTruncated = false
        /// Why the engine stopped before reading everything the search
        /// covers, which leaves these results incomplete; `nil` when it read
        /// it all.
        public var stopReason: RuntimeInterfaceSearchStopReason?
        /// Hits the engine left out of the count because they sit in an
        /// Objective-C protocol copy that reads exactly like one already
        /// shown, across every search merged into these results.
        public var omittedRepeatedMatchCount = 0
        /// The query these results answer: the one last run, not the one
        /// the mode path and the toggles may have been edited into since. A
        /// click highlights with its mode and case. `nil` with nothing
        /// searched.
        public internal(set) var query: FindQuery?

        public init() {}
    }

    /// The most hits or members a search collects, across every image it
    /// reads; the count goes on past it.
    nonisolated static let resultLimit = 1000

    /// What the summary bar adds when the engine stopped a regular
    /// expression that spent the search's time budget backtracking.
    static let regularExpressionTooExpensiveNotice = "incomplete: the pattern takes too long to match"

    /// The summary bar for a source whose RuntimeViewer predates Find's
    /// commands, worded as the Report navigator words it.
    nonisolated static let unsupportedBySourceSummary = "Not supported by this source"

    /// What the summary bar adds when the engine folded the hits of
    /// Objective-C protocol copies that read exactly like one already shown —
    /// the same declaration, carried by another image — so a total lower than
    /// the copies suggest has its explanation in view.
    static func foldedProtocolCopiesNotice(count: Int) -> String {
        "\(count) more in identical protocol copies"
    }

    /// Weak: the session can outlive its document — a page's view model holds
    /// it while the window comes down — and is then still subscribed to the
    /// Generation Options every window shares until the document closes it.
    /// A search under way does not keep it: its task holds the run, not the
    /// session.
    private weak var documentState: DocumentState?

    @RxObserved
    public private(set) var query: FindQuery = FindQuery()

    @RxObserved
    public private(set) var results: Results = Results()

    @RxObserved
    public private(set) var isSearching: Bool = false

    /// The summary bar: the results' own summary, then what is still being
    /// made searchable — `2 images being made searchable · building
    /// Foundation 37%` — or, while nothing is being built, how many indexed
    /// images the search could not see. `nil` hides the bar.
    @RxObserved
    public private(set) var summary: String? = nil

    /// Fired when a page should take the keyboard focus into its search
    /// field — Edit ▸ Find ▸ Find in Indexed Images.
    public let focusSearchFieldRelay = PublishRelay<Void>()

    /// Asks the window to show the Find navigator, its results on screen and
    /// its query field left alone: a cross-reference command ran from outside
    /// the page. See `runCrossReferenceCommand(_:)`.
    public var showResultsRequested: Signal<Void> {
        showResultsRelay.asSignal()
    }

    private let showResultsRelay = PublishRelay<Void>()

    /// Whether Callees lists the calls to retains, releases and the other
    /// runtime helpers. The filter bar's toggle; off, as most callees lists
    /// would otherwise be mostly those.
    @RxObserved
    public private(set) var showsRuntimeHelperCalls: Bool = false

    /// The engine call under way, if any; see `SearchRun`.
    private var currentRun: SearchRun?

    /// The task making `currentRun`'s engine call. Kept on the session, not
    /// on the run, so `deinit` can cancel it.
    private var searchTask: Task<Void, Never>?

    /// The query whose results are on screen: the one last run, whatever the
    /// mode path and the toggles show by now. `nil` before the first search
    /// and once the field is cleared.
    private var committedQuery: FindQuery?

    private var textMatchGroups = MatchGroups<RuntimeInterfaceSearchMatch>()

    private var memberMatchGroups = MatchGroups<RuntimeMemberMatch>()

    /// The text or member search `results` shows, kept so a corpus built
    /// later can be read by it. `nil` for no search, a relationship search
    /// or a failed one.
    private var shownSearch: ShownSearch?

    /// Corpora built while a search was running, read once it ends.
    private var imagePathsBuiltDuringSearch: Set<String> = []

    /// The corpus coordinator's build states, for the summary bar.
    private var corpusBuildStates: [String: RuntimeInterfaceCorpusBuildState] = [:]

    /// The coordinator `follow(_:)` hooked the session to — the corpus
    /// coordinator of the engine the document is on, which every document on
    /// the engine shares; it moves the images in scope to the front of its
    /// queue. `nil` until it exists, and the session never brings it into
    /// being itself.
    private weak var corpusCoordinator: FindCorpusCoordinator?

    @Dependency(\.appDefaults)
    private var appDefaults

    @Dependency(\.settings)
    private var settings

    /// The cross-reference tree on screen; `nil` for any other search.
    private var crossReferenceTree: FindCrossReferenceTree?

    /// What each expandable row of `crossReferenceTree` loads, as of the rows
    /// last published.
    private var crossReferenceLoadRequests: [String: FindCrossReferenceTree.LoadRequest] = [:]

    /// The rows waiting for their level, in the order they were expanded.
    private var crossReferenceLoadQueue: [String] = []

    /// The level loading now, and its task; see `SearchRun`.
    private var crossReferenceLoadRun: SearchRun?

    private var crossReferenceLoadTask: Task<Void, Never>?

    /// How far the level loading now has come, for the summary bar.
    private var crossReferenceLoadProgress: (scannedImageCount: Int, totalImageCount: Int)?

    /// The images the scope of the tree on screen stood for when it ran; `nil`
    /// for every indexed image.
    private var crossReferenceScopeImagePaths: Set<String>?

    /// The roots' term searched indexed images whose corpus is not built.
    private var crossReferenceUnbuiltImageCount = 0

    /// Levels that stopped at `crossReferenceResultLimit`.
    private var truncatedCrossReferenceLevelCount = 0

    /// The most references one level brings back. `init` alone is called from
    /// hundreds of thousands of places.
    nonisolated static let crossReferenceResultLimit = 10000

    /// Replaced when the document closes, which ends every subscription.
    private var disposeBag = DisposeBag()

    /// The subscriptions to the coordinator `follow(_:)` hooked the session
    /// to, replaced when the document moves to another engine's and when the
    /// document closes.
    private var corpusCoordinatorDisposeBag = DisposeBag()

    public init(documentState: DocumentState) {
        self.documentState = documentState
        appDefaults.$options
            .distinctUntilChanged()
            .skip(1)
            .observe(on: MainScheduler.instance)
            .subscribeOnNext { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.rerunShownSearch()
                }
            }
            .disposed(by: disposeBag)
        documentState.runtimeEngineDidReset
            .asObservable()
            // One turn later. The engine coming back reaches its corpus
            // coordinator from the engine itself, on a main-actor turn queued
            // ahead of this one, and that coordinator then starts over;
            // searching at once would put the scope's images at the front of a
            // queue it is about to withdraw.
            .observe(on: MainScheduler.asyncInstance)
            .subscribeOnNext { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.engineDidChange()
                }
            }
            .disposed(by: disposeBag)
    }

    deinit {
        searchTask?.cancel()
        crossReferenceLoadTask?.cancel()
    }

    /// The document is closing. The search under way is cancelled, and nothing
    /// starts another one: not a Generation Options change made in another
    /// window, not a corpus the coordinator reports built, not an engine
    /// switch.
    public func documentWillClose() {
        // A search still finishing finds it is no longer the current run and
        // leaves the session alone, `isSearching` included.
        cancelCurrentRun()
        isSearching = false
        disposeBag = DisposeBag()
        corpusCoordinatorDisposeBag = DisposeBag()
    }

    /// Hooks the session to the corpus coordinator of the document's engine.
    /// `DocumentState` calls this once the document needs that coordinator,
    /// and again with the next engine's each time the document moves to
    /// another engine: its build states feed the summary bar, and each corpus
    /// it reports built is read by the search in force. Once every corpus is
    /// dropped to be printed with a new transformer, that search runs again:
    /// the images rebuilt are ones it has already read.
    func follow(_ corpusCoordinator: FindCorpusCoordinator) {
        guard self.corpusCoordinator !== corpusCoordinator else { return }
        self.corpusCoordinator = corpusCoordinator
        corpusCoordinatorDisposeBag = DisposeBag()
        corpusCoordinator.$buildStatesByImagePath.asDriver()
            .driveOnNextMainActor { [weak self] states in
                guard let self else { return }
                self.corpusBuildStates = states
                self.updateSummary()
            }
            .disposed(by: corpusCoordinatorDisposeBag)
        corpusCoordinator.corpusBuilt
            .emitOnNextMainActor { [weak self] imagePath in
                guard let self else { return }
                self.corpusDidBuild(at: imagePath)
            }
            .disposed(by: corpusCoordinatorDisposeBag)
        corpusCoordinator.corporaRebuilt
            .emitOnNextMainActor { [weak self] in
                guard let self else { return }
                self.rerunShownSearch()
            }
            .disposed(by: corpusCoordinatorDisposeBag)
    }

    // MARK: - Query

    /// Changes the query without searching; the next `run` uses it. The
    /// mode path, the case toggle, the member kinds and the scope chooser
    /// call this. A scope that changes moves its images still waiting for
    /// their corpus to the front of the queue, so they are ready sooner.
    public func update(_ change: (inout FindQuery) -> Void) {
        var updated = query
        change(&updated)
        guard updated != query else { return }
        let isScopeChanged = updated.scope != query.scope
        query = updated
        if isScopeChanged {
            prioritizeCorpora(of: imagePaths(of: updated.scope))
        }
    }

    /// Runs `query` (Return in the search field). An empty query clears the
    /// results instead.
    public func run(_ query: FindQuery) {
        self.query = query
        start(query)
    }

    /// Runs `query` without touching the one the page edits, so a search run
    /// again on another engine leaves the mode path and the toggles as the
    /// user left them.
    private func start(_ query: FindQuery) {
        cancelCurrentRun()
        committedQuery = query.isEmpty ? nil : query
        resetResults()
        guard !query.isEmpty else {
            isSearching = false
            return
        }
        let scopeImagePaths = query.mode.usesScope ? imagePaths(of: query.scope) : nil
        if scopeImagePaths?.isEmpty == true {
            isSearching = false
            var nothingToSearch = Results()
            nothingToSearch.summary = "No current image"
            setResults(nothingToSearch)
            return
        }
        if query.mode.crossReferenceDirection != nil {
            startCrossReferenceSearch(query, scopeImagePaths: scopeImagePaths)
            return
        }
        prioritizeCorpora(of: scopeImagePaths)
        let generationOptions = appDefaults.options
        if query.mode.relationship == nil {
            shownSearch = ShownSearch(query: query, generationOptions: generationOptions, scopeImagePaths: scopeImagePaths)
        }
        startSearch(query, imagePaths: scopeImagePaths, generationOptions: generationOptions, isWidening: false)
    }

    /// Runs the query in force again.
    public func rerun() {
        run(query)
    }

    /// Find Call Hierarchy, Find Callees or Find Type References from outside
    /// the Find page — the content pane, the Inspector, the main menu. The
    /// query runs at once and is recorded among the recent queries, and the
    /// window is asked to show the navigator without focusing its query field,
    /// as Xcode's Find Call Hierarchy does
    /// (`-[IDEFindNavigatorCommands initiateCallHierarchyQueryWithSymbol:inWorkspaceTabController:]`).
    public func runCrossReferenceCommand(_ request: FindCrossReferenceRequest) {
        let commandQuery = query.crossReferenceQuery(request.mode, for: request.root)
        run(commandQuery)
        recordAsRecent(commandQuery)
        showResultsRelay.accept(())
    }

    /// Records `query` among the recent queries of the document's source, as a
    /// query the user ran (`-[IDEFindNavigatorQueryParametersController
    /// initiateQuery]`). A search that runs again by itself is not recorded.
    func recordAsRecent(_ query: FindQuery) {
        guard !query.isEmpty, let documentState else { return }
        let key = documentState.runtimeEngine.bookmarkScope.bookmarkKey
        appDefaults.findRecentQueriesByScope[key] = FindRecentQueries.recording(query, in: appDefaults.findRecentQueriesByScope[key] ?? [])
    }

    /// A text or member search on screen answers for the options it ran
    /// under; run it again so it answers for the ones the content pane now
    /// displays with — or, after a transformer change, for the corpora being
    /// printed again, which come back one by one as they are rebuilt. It is
    /// the search on screen that runs again, over the images its scope stood
    /// for then: not the query the mode path and the toggles are being edited
    /// into, which stays as it is. Relationship searches depend on neither.
    private func rerunShownSearch() {
        guard let shownSearch else { return }
        let generationOptions = appDefaults.options
        cancelCurrentRun()
        resetResults()
        self.shownSearch = ShownSearch(query: shownSearch.query, generationOptions: generationOptions, scopeImagePaths: shownSearch.scopeImagePaths)
        prioritizeCorpora(of: shownSearch.scopeImagePaths)
        startSearch(shownSearch.query, imagePaths: shownSearch.scopeImagePaths, generationOptions: generationOptions, isWidening: false)
    }

    /// Empties the results and everything the search on screen gathered.
    private func resetResults() {
        shownSearch = nil
        crossReferenceTree = nil
        crossReferenceLoadRequests = [:]
        crossReferenceScopeImagePaths = nil
        crossReferenceUnbuiltImageCount = 0
        truncatedCrossReferenceLevelCount = 0
        imagePathsBuiltDuringSearch = []
        textMatchGroups = MatchGroups<RuntimeInterfaceSearchMatch>()
        memberMatchGroups = MatchGroups<RuntimeMemberMatch>()
        setResults(Results())
    }

    public func clear() {
        var cleared = query
        cleared.term = FindQueryTerm()
        run(cleared)
    }

    /// The document moved to another engine, or its engine came back with a
    /// new process behind it: nothing on screen belongs to that process. The
    /// search on screen runs again on it, under the same scope; a cleared
    /// field stays cleared.
    private func engineDidChange() {
        guard let committedQuery else { return }
        start(committedQuery)
    }

    // MARK: - Scope

    /// The images `scope` stands for now: `nil` for every indexed image, and
    /// an empty set when it is the sidebar's image while the sidebar lists
    /// none.
    private func imagePaths(of scope: FindScope) -> Set<String>? {
        switch scope {
        case .allIndexedImages:
            nil
        case .currentImage:
            // A closed document has no sidebar, so no image either.
            (documentState?.currentImageNode).map { [$0.path] } ?? []
        case .images(let imagePaths):
            imagePaths
        }
    }

    /// Moves the images in scope still waiting for their corpus to the front
    /// of the coordinator's queue — one waiting already only moves, one that
    /// failed is asked for again. A scope of every indexed image has no
    /// favourites.
    private func prioritizeCorpora(of scopeImagePaths: Set<String>?) {
        guard let scopeImagePaths, let corpusCoordinator else { return }
        for imagePath in scopeImagePaths.sorted() where corpusCoordinator.buildState(forImagePath: imagePath)?.isBuilt != true {
            corpusCoordinator.requestBuild(of: imagePath, isPrioritized: true)
        }
    }

    /// `imagePath` as the document's engine keys it: the form of the corpus
    /// coordinator's states, of the engine's summaries and of the corpora it
    /// reports built. A scope and the sidebar spell an image without an iOS
    /// Simulator's root, so two paths are compared only once both are in
    /// this form; see `RuntimeEngine.canonicalImagePath(_:)`.
    private func canonicalImagePath(_ imagePath: String) -> String {
        documentState?.runtimeEngine.canonicalImagePath(imagePath) ?? imagePath
    }

    private func canonicalImagePaths(_ imagePaths: Set<String>) -> Set<String> {
        Set(imagePaths.map(canonicalImagePath))
    }

    // MARK: - Execution

    /// What a text or member search on screen ran under and has read so
    /// far, and its running totals: everything an image built later needs to
    /// be searched the same way and merged in.
    private struct ShownSearch {
        let query: FindQuery
        let generationOptions: RuntimeObjectInterface.GenerationOptions
        /// The images the scope stood for when the search ran; `nil` for
        /// every indexed image. A corpus built later is read only inside it.
        let scopeImagePaths: Set<String>?
        var searchedImagePaths: Set<String> = []
        var totalMatchCount = 0
        var omittedRepeatedMatchCount = 0
        var isTruncated = false
    }

    /// One engine call: a search, or a widening of the one on screen. What it
    /// brings back is applied only while it is `currentRun`. Cancelling the
    /// call stops it — in a serving process too — and nothing reaches the
    /// session from the engine afterwards, but a batch or a reply already on
    /// its way to the main actor still arrives, behind whatever the window was
    /// busy with; it is dropped here instead of landing in the results of the
    /// search that replaced it. Identity is all a run carries.
    private final class SearchRun: Sendable {}

    /// The engine request a query makes.
    private enum SearchRequest: Sendable {
        case text(RuntimeInterfaceSearchQuery)
        case members(RuntimeMemberSearchQuery)
        case relationships(RuntimeTypeRelationshipsQuery)
    }

    /// What the engine answered a `SearchRequest` with.
    private enum SearchResponse: Sendable {
        case text(RuntimeInterfaceSearchSummary)
        case members(RuntimeInterfaceSearchSummary)
        case relationships([RuntimeRelationshipTree])
    }

    /// Runs `query` over `imagePaths` — every built image when `nil` — and
    /// folds what it finds into the results. A search that widens one already
    /// shown keeps the results it is merged into when it fails.
    private func startSearch(_ query: FindQuery, imagePaths: Set<String>?, generationOptions: RuntimeObjectInterface.GenerationOptions, isWidening: Bool) {
        cancelCurrentRun()
        // The session outlived its document: there is nothing to search.
        guard let engine = documentState?.runtimeEngine else {
            isSearching = false
            return
        }
        let run = SearchRun()
        currentRun = run
        isSearching = true
        let request = searchRequest(for: query, imagePaths: imagePaths, generationOptions: generationOptions)
        // The task holds the run, never the session: a document that goes
        // away mid-search takes its session with it, and the session's
        // `deinit` withdraws the call.
        searchTask = Task { [weak self] in
            let outcome: Result<SearchResponse, any Swift.Error>
            do {
                switch request {
                case .text(let engineQuery):
                    let summary = try await engine.searchInterfaces(engineQuery) { [weak self] batch in
                        guard let self else { return }
                        await appendTextMatches(batch, from: run)
                    }
                    outcome = .success(.text(summary))
                case .members(let engineQuery):
                    let summary = try await engine.searchMembers(engineQuery) { [weak self] batch in
                        guard let self else { return }
                        await appendMemberMatches(batch, from: run)
                    }
                    outcome = .success(.members(summary))
                case .relationships(let engineQuery):
                    outcome = .success(.relationships(try await engine.typeRelationships(engineQuery)))
                }
            } catch {
                outcome = .failure(error)
            }
            // After the awaits: the session is not kept alive while the engine searches.
            guard let self else { return }
            runDidEnd(run, with: outcome, isWidening: isWidening)
        }
    }

    /// A query with find patterns goes out as a regular expression, the
    /// engine's form for anything that is not literal text; see
    /// `FindQueryTerm.searchText(literalMatchMode:isRegularExpression:)`.
    private func searchRequest(for query: FindQuery, imagePaths: Set<String>?, generationOptions: RuntimeObjectInterface.GenerationOptions) -> SearchRequest {
        switch query.mode {
        case .text, .regularExpression:
            let searchText = query.textSearchText
            return .text(RuntimeInterfaceSearchQuery(
                text: searchText.text,
                matchMode: searchText.matchMode,
                isCaseSensitive: query.isCaseSensitive,
                scope: .all,
                resultLimit: max(0, Self.resultLimit - textMatchGroups.matchCount),
                generationOptions: generationOptions,
                imagePaths: imagePaths
            ))
        case .members, .callHierarchy, .callees, .typeReferences:
            // The cross-reference modes never come this way — `start(_:)` hands
            // them to `startCrossReferenceSearch` — and would only list members.
            let searchText = query.memberSearchText
            return .members(RuntimeMemberSearchQuery(
                text: searchText.text,
                matchMode: searchText.matchMode,
                kinds: query.memberKindFilter.kinds,
                isCaseSensitive: query.isCaseSensitive,
                resultLimit: max(0, Self.resultLimit - memberMatchGroups.matchCount),
                generationOptions: generationOptions,
                imagePaths: imagePaths
            ))
        case .ancestorTypes, .descendantTypes, .conformingTypes:
            let searchText = query.relationshipSearchText
            return .relationships(RuntimeTypeRelationshipsQuery(
                text: searchText.text,
                matchMode: searchText.matchMode,
                relationship: query.mode.relationship ?? .ancestors,
                isCaseSensitive: query.isCaseSensitive,
                imagePaths: imagePaths
            ))
        }
    }

    /// An engine call came to its end. One that is no longer `currentRun`
    /// was replaced — by a newer search, an engine switch, the document
    /// closing — and the results are not its to touch. The current one,
    /// whatever its outcome, leaves the session idle and reads the corpora
    /// built while it ran.
    private func runDidEnd(_ run: SearchRun, with outcome: Result<SearchResponse, any Swift.Error>, isWidening: Bool) {
        guard run === currentRun else { return }
        currentRun = nil
        searchTask = nil
        switch outcome {
        case .success(.text(let summary)):
            finish(with: summary, nodes: textMatchGroups.nodes(), typeCount: textMatchGroups.typeCount, isWidening: isWidening)
        case .success(.members(let summary)):
            finish(with: summary, nodes: memberMatchGroups.nodes(), typeCount: memberMatchGroups.typeCount, isWidening: isWidening)
        case .success(.relationships(let trees)):
            showRelationshipTrees(trees)
        case .failure(is CancellationError):
            // Cancelled on the engine's side: there is nothing to show.
            break
        case .failure(let error):
            #log(.error, "Find failed: \(error, privacy: .public)")
            // A widening search keeps the results it would have merged into,
            // and the images it was sent to read stay unsearched; it is not
            // tried again, which a connection that is gone would turn into a
            // loop. Until it went idle here, every corpus built later waited
            // on it.
            if !isWidening {
                shownSearch = nil
                var failed = Results()
                failed.summary = Self.failureSummary(for: error)
                setResults(failed)
            }
        }
        isSearching = false
        searchImagesBuiltDuringSearch()
    }

    /// Stops the engine call under way and stops listening to it: whatever it
    /// still delivers is dropped. A cross-reference level loading stops with
    /// it, and so do the ones waiting.
    private func cancelCurrentRun() {
        searchTask?.cancel()
        searchTask = nil
        currentRun = nil
        crossReferenceLoadTask?.cancel()
        crossReferenceLoadTask = nil
        crossReferenceLoadRun = nil
        crossReferenceLoadQueue = []
        crossReferenceLoadProgress = nil
    }

    /// The trees a relationship search answered with, one per matching type.
    private func showRelationshipTrees(_ trees: [RuntimeRelationshipTree]) {
        var nodes: [FindResultNode] = []
        var relatedTypeCount = 0
        for tree in trees {
            let children = tree.nodes.enumerated().map { index, node in
                FindResultNode.relationship(node, path: "tree|\(tree.root.kind)|\(tree.root.name)|\(tree.root.imagePath)#\(index)")
            }
            relatedTypeCount += Self.count(children)
            nodes.append(FindResultNode.object(tree.root, children: children))
        }
        var relationshipResults = Results()
        relationshipResults.nodes = nodes
        relationshipResults.summary = nodes.isEmpty
            ? "No matching types"
            : "\(relatedTypeCount) \(relatedTypeCount == 1 ? "type" : "types") for \(nodes.count) \(nodes.count == 1 ? "match" : "matches")"
        setResults(relationshipResults)
    }

    /// One image's batch, folded into the tree while the search goes on — if
    /// the call that brought it is still the current one.
    private func appendTextMatches(_ batch: [RuntimeInterfaceSearchMatch], from run: SearchRun) {
        guard run === currentRun else { return }
        textMatchGroups.append(batch)
        setResults(results(from: textMatchGroups.nodes(), matchCount: (shownSearch?.totalMatchCount ?? 0) + textMatchGroups.matchCountSinceLastFinish, typeCount: textMatchGroups.typeCount))
    }

    private func appendMemberMatches(_ batch: [RuntimeMemberMatch], from run: SearchRun) {
        guard run === currentRun else { return }
        memberMatchGroups.append(batch)
        setResults(results(from: memberMatchGroups.nodes(), matchCount: (shownSearch?.totalMatchCount ?? 0) + memberMatchGroups.matchCountSinceLastFinish, typeCount: memberMatchGroups.typeCount))
    }

    /// A text or member search came to its end: its totals join the ones
    /// shown, and the images it read join the ones searched. A widening
    /// search's own summary covers only the images it was sent to read, so
    /// the images still unsearchable are the ones before it, less those it
    /// read.
    private func finish(with summary: RuntimeInterfaceSearchSummary, nodes: [FindResultNode], typeCount: Int, isWidening: Bool) {
        textMatchGroups.markFinished()
        memberMatchGroups.markFinished()
        guard var shownSearch else { return }
        shownSearch.searchedImagePaths.formUnion(summary.scannedImagePaths)
        shownSearch.totalMatchCount += summary.totalMatchCount
        shownSearch.omittedRepeatedMatchCount += summary.omittedRepeatedMatchCount
        shownSearch.isTruncated = shownSearch.isTruncated || summary.isTruncated
        self.shownSearch = shownSearch
        var finished = results(from: nodes, matchCount: shownSearch.totalMatchCount, typeCount: typeCount)
        // A search that stopped early leaves the results incomplete, and a
        // widening search merged into them does not make them whole.
        finished.stopReason = isWidening ? (summary.stopReason ?? results.stopReason) : summary.stopReason
        if isWidening {
            let scannedImagePaths = Set(summary.scannedImagePaths)
            finished.unbuiltImagePaths = results.unbuiltImagePaths.filter { !scannedImagePaths.contains($0) }
        } else {
            finished.unbuiltImagePaths = summary.unbuiltIndexedImagePaths
        }
        setResults(finished)
        // What the search could not read is asked for now — an image the
        // store evicted behind the coordinator's back included: this is the
        // moment the user has just been told it is missing.
        corpusCoordinator?.reconcile(unbuiltIndexedImagePaths: summary.unbuiltIndexedImagePaths, scopeImagePaths: shownSearch.scopeImagePaths)
    }

    /// A corpus the coordinator reports built is read by the search on
    /// screen, unless it already was; a search still running reads it once
    /// it ends.
    ///
    /// Internal so a test can stand in for the coordinator.
    func corpusDidBuild(at imagePath: String) {
        guard shownSearch != nil else { return }
        imagePathsBuiltDuringSearch.insert(imagePath)
        guard !isSearching else { return }
        searchImagesBuiltDuringSearch()
    }

    private func searchImagesBuiltDuringSearch() {
        let builtImagePaths = canonicalImagePaths(imagePathsBuiltDuringSearch)
        imagePathsBuiltDuringSearch = []
        guard let shownSearch else { return }
        var unsearchedImagePaths = builtImagePaths.subtracting(canonicalImagePaths(shownSearch.searchedImagePaths))
        if let scopeImagePaths = shownSearch.scopeImagePaths {
            unsearchedImagePaths.formIntersection(canonicalImagePaths(scopeImagePaths))
        }
        guard !unsearchedImagePaths.isEmpty else { return }
        startSearch(shownSearch.query, imagePaths: unsearchedImagePaths, generationOptions: shownSearch.generationOptions, isWidening: true)
    }

    private static func count(_ nodes: [FindResultNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + count($1.children) }
    }

    /// `N results in M types`, with the truncation of the search on screen
    /// and the images it could not see carried over.
    private func results(from nodes: [FindResultNode], matchCount: Int, typeCount: Int) -> Results {
        var updated = Results()
        updated.nodes = nodes
        updated.isTruncated = shownSearch?.isTruncated ?? false
        updated.omittedRepeatedMatchCount = shownSearch?.omittedRepeatedMatchCount ?? 0
        updated.unbuiltImagePaths = results.unbuiltImagePaths
        updated.stopReason = results.stopReason
        var text = "\(matchCount) \(matchCount == 1 ? "result" : "results") in \(typeCount) \(typeCount == 1 ? "type" : "types")"
        if updated.isTruncated {
            text += ", showing the first \(nodes.reduce(0) { $0 + $1.children.count })"
        }
        updated.summary = text
        return updated
    }

    // MARK: - Cross References

    /// Starts a Call Hierarchy, Callees or Type References search: the root a
    /// command named, or the ones the term finds, then the levels of the roots
    /// that open as they arrive.
    private func startCrossReferenceSearch(_ query: FindQuery, scopeImagePaths: Set<String>?) {
        crossReferenceScopeImagePaths = scopeImagePaths
        if let root = query.crossReferenceRoot {
            showCrossReferenceRoots([root], for: query)
            return
        }
        // The session outlived its document: there is nothing to search.
        guard let engine = documentState?.runtimeEngine else {
            isSearching = false
            return
        }
        let run = SearchRun()
        currentRun = run
        isSearching = true
        let generationOptions = appDefaults.options
        // As `startSearch`: the task holds the run, never the session.
        searchTask = Task { [weak self] in
            let outcome: Result<FindCrossReferenceRootResolver.Resolution, any Swift.Error>
            do {
                outcome = .success(try await FindCrossReferenceRootResolver.resolve(query, engine: engine, generationOptions: generationOptions))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            crossReferenceRootsDidResolve(run, outcome: outcome, for: query)
        }
    }

    private func crossReferenceRootsDidResolve(_ run: SearchRun, outcome: Result<FindCrossReferenceRootResolver.Resolution, any Swift.Error>, for query: FindQuery) {
        guard run === currentRun else { return }
        currentRun = nil
        searchTask = nil
        switch outcome {
        case .success(let resolution):
            crossReferenceUnbuiltImageCount = resolution.unbuiltImageCount
            showCrossReferenceRoots(resolution.roots, for: query)
        case .failure(is CancellationError):
            isSearching = false
        case .failure(let error):
            #log(.error, "Find failed: \(error, privacy: .public)")
            isSearching = false
            var failed = Results()
            failed.summary = Self.failureSummary(for: error)
            setResults(failed)
        }
    }

    /// Shows the roots, and loads the levels of the ones that open.
    private func showCrossReferenceRoots(_ roots: [FindCrossReferenceRoot], for query: FindQuery) {
        guard let direction = query.mode.crossReferenceDirection else { return }
        let tree = FindCrossReferenceTree(direction: direction, roots: roots)
        crossReferenceTree = tree
        // The rows first, for the load requests the queue is checked against;
        // then the first level, and the rows once more with it loading.
        publishCrossReferenceTree()
        for identifier in roots.indices.map(tree.rootIdentifier(at:)) where tree.expandedIdentifiers.contains(identifier) {
            enqueueCrossReferenceLevel(of: identifier)
        }
        if startNextCrossReferenceLevel() {
            publishCrossReferenceTree()
        }
        updateCrossReferenceSearchingState()
    }

    /// The rows of the cross-reference tree on screen that show expanded: the
    /// roots it opened, and the rows the user expanded and has not collapsed.
    public var crossReferenceExpandedIdentifiers: Set<String> {
        crossReferenceTree?.expandedIdentifiers ?? []
    }

    /// A row of the cross-reference tree was expanded — by the user, or by the
    /// page putting an expansion back. Its level loads, unless it has.
    ///
    /// The load starts on the main actor's next turn, never inside this call:
    /// the page puts expansions back while it applies the rows the session
    /// last published, and publishing again from in there would deliver new
    /// rows to the page in the middle of applying the old ones — RxSwift's
    /// "Reentrancy anomaly", seen when a finished level let the next one start
    /// as the page re-expanded its rows.
    public func crossReferenceRowDidExpand(_ identifier: String) {
        guard crossReferenceTree != nil else { return }
        crossReferenceTree?.expand(identifier)
        enqueueCrossReferenceLevel(of: identifier)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if startNextCrossReferenceLevel() {
                publishCrossReferenceTree()
            }
            updateCrossReferenceSearchingState()
        }
    }

    public func crossReferenceRowDidCollapse(_ identifier: String) {
        crossReferenceTree?.collapse(identifier)
    }

    /// The filter bar's Show Runtime Calls toggle.
    public func setShowsRuntimeHelperCalls(_ showsRuntimeHelperCalls: Bool) {
        guard showsRuntimeHelperCalls != self.showsRuntimeHelperCalls else { return }
        self.showsRuntimeHelperCalls = showsRuntimeHelperCalls
        if crossReferenceTree?.direction == .callees {
            publishCrossReferenceTree()
        }
    }

    private func enqueueCrossReferenceLevel(of identifier: String) {
        guard let crossReferenceTree,
              crossReferenceTree.loadState(of: identifier) == nil,
              crossReferenceLoadRequests[identifier] != nil,
              !crossReferenceLoadQueue.contains(identifier)
        else { return }
        crossReferenceLoadQueue.append(identifier)
    }

    /// Starts the next level waiting, unless one is loading, and says whether
    /// it started one. It publishes nothing: the caller publishes the rows
    /// once, with whatever else it changed.
    private func startNextCrossReferenceLevel() -> Bool {
        guard crossReferenceLoadRun == nil,
              let engine = documentState?.runtimeEngine,
              let direction = crossReferenceTree?.direction
        else { return false }
        while !crossReferenceLoadQueue.isEmpty {
            let identifier = crossReferenceLoadQueue.removeFirst()
            guard crossReferenceTree?.loadState(of: identifier) == nil, let request = crossReferenceLoadRequests[identifier] else { continue }
            let run = SearchRun()
            crossReferenceLoadRun = run
            crossReferenceLoadProgress = nil
            crossReferenceTree?.setLoadState(.loading, of: identifier)
            let scopes = crossReferenceScopes()
            let maximumConcurrentScans = settings.search.maximumConcurrentCrossReferenceScans
            crossReferenceLoadTask = Task { [weak self] in
                let outcome: Result<RuntimeCrossReferenceQueryResult, any Swift.Error>
                do {
                    outcome = .success(try await Self.loadLevel(request, direction: direction, scopes: scopes, maximumConcurrentScans: maximumConcurrentScans, engine: engine) { [weak self] progress in
                        await self?.crossReferenceLevelDidProgress(progress, from: run)
                    })
                } catch {
                    outcome = .failure(error)
                }
                guard let self else { return }
                crossReferenceLevelDidLoad(identifier, outcome: outcome, from: run)
            }
            return true
        }
        return false
    }

    /// One level: a row's callers, its callees with the runtime helper calls
    /// among them, or the functions referencing a type — over each of
    /// `scopes` in turn, each image of a scope naming several asked for alone,
    /// and at most `maximumConcurrentScans` images scanned at once.
    private nonisolated static func loadLevel(
        _ request: FindCrossReferenceTree.LoadRequest,
        direction: FindCrossReferenceDirection,
        scopes: [RuntimeCrossReferenceScope],
        maximumConcurrentScans: Int,
        engine: RuntimeEngine,
        reportProgress: @escaping @Sendable (RuntimeCrossReferenceQueryProgress) async -> Void
    ) async throws -> RuntimeCrossReferenceQueryResult {
        if case .calls(let subject) = request, direction == .callees {
            return try await engine.callees(of: subject, options: RuntimeCrossReferenceQueryOptions(includesRuntimeHelperCalls: true, resultLimit: crossReferenceResultLimit))
        }
        var references: [RuntimeCrossReference] = []
        var isComplete = true
        for (index, scope) in scopes.enumerated() {
            let remainingLimit = crossReferenceResultLimit - references.count
            guard remainingLimit > 0 else {
                isComplete = false
                break
            }
            let options = RuntimeCrossReferenceQueryOptions(resultLimit: remainingLimit, maximumConcurrentScans: maximumConcurrentScans)
            // A scope of one image reports nothing in between; one of several
            // reports each image as it is done instead.
            let silentProgress: @Sendable (RuntimeCrossReferenceQueryProgress) async -> Void = { _ in }
            let scopeProgress = scopes.count == 1 ? reportProgress : silentProgress
            let result: RuntimeCrossReferenceQueryResult
            switch request {
            case .calls(let subject):
                result = try await engine.callers(of: subject, in: scope, options: options, reportProgress: scopeProgress)
            case .typeReferences(let object):
                result = try await engine.typeReferences(to: object, in: scope, options: options, reportProgress: scopeProgress)
            }
            references.append(contentsOf: result.references)
            isComplete = isComplete && result.isComplete
            if scopes.count > 1 {
                await reportProgress(RuntimeCrossReferenceQueryProgress(scannedImageCount: index + 1, totalImageCount: scopes.count, references: []))
            }
        }
        return RuntimeCrossReferenceQueryResult(references: references, isComplete: isComplete)
    }

    private func crossReferenceLevelDidProgress(_ progress: RuntimeCrossReferenceQueryProgress, from run: SearchRun) {
        guard run === crossReferenceLoadRun else { return }
        crossReferenceLoadProgress = (progress.scannedImageCount, progress.totalImageCount)
        var updatedResults = results
        updatedResults.summary = crossReferenceSummary()
        guard updatedResults.summary != results.summary else { return }
        setResults(updatedResults)
    }

    private func crossReferenceLevelDidLoad(_ identifier: String, outcome: Result<RuntimeCrossReferenceQueryResult, any Swift.Error>, from run: SearchRun) {
        guard run === crossReferenceLoadRun, var tree = crossReferenceTree else { return }
        crossReferenceLoadRun = nil
        crossReferenceLoadTask = nil
        crossReferenceLoadProgress = nil
        switch outcome {
        case .success(let result):
            if !result.isComplete {
                truncatedCrossReferenceLevelCount += 1
            }
            tree.setLoadState(.loaded(FindCrossReferenceTree.rows(for: result.references, direction: tree.direction)), of: identifier)
        case .failure(is CancellationError):
            // Cancelled on the engine's side: the row loads again when it is
            // expanded again.
            tree.clearLoadState(of: identifier)
        case .failure(let error):
            #log(.error, "Cross references failed: \(error, privacy: .public)")
            tree.setLoadState(.failed(Self.crossReferenceFailureMessage(for: error)), of: identifier)
        }
        crossReferenceTree = tree
        // The next level starts before the rows are published, so one update
        // carries both: the page re-expands rows as it applies it.
        _ = startNextCrossReferenceLevel()
        publishCrossReferenceTree()
        updateCrossReferenceSearchingState()
    }

    /// The engine's scopes for the tree's levels: every indexed image, or each
    /// image the scope names, which the engine scans one at a time or all
    /// together. Each image is asked for by its own path, which the process
    /// serving the engine resolves; the results name images as that process
    /// does, which the paths of a scope may spell otherwise.
    private func crossReferenceScopes() -> [RuntimeCrossReferenceScope] {
        guard let scopeImagePaths = crossReferenceScopeImagePaths.map(canonicalImagePaths) else {
            return [.indexedImages]
        }
        return scopeImagePaths.sorted().map { .image(path: $0) }
    }

    private func updateCrossReferenceSearchingState() {
        isSearching = currentRun != nil || crossReferenceLoadRun != nil || !crossReferenceLoadQueue.isEmpty
    }

    /// Publishes the tree's rows and what the summary bar says of them.
    private func publishCrossReferenceTree() {
        guard let crossReferenceTree else { return }
        let built = crossReferenceTree.build(showsRuntimeHelperCalls: showsRuntimeHelperCalls)
        crossReferenceLoadRequests = built.loadRequests
        var treeResults = Results()
        treeResults.nodes = built.nodes
        treeResults.summary = crossReferenceSummary()
        setResults(treeResults)
    }

    /// Nothing while there are rows and nothing loads — Xcode's call hierarchy
    /// has no summary row (`-[IDEBatchFindCallHierarchyQuery
    /// publishesMatchCount]` is NO); how far a level's scan has come while one
    /// loads; and Xcode's words when the term found nothing
    /// (`-emptyResultSetPlaceholderForSpecification:term:scope:`).
    private func crossReferenceSummary() -> String? {
        guard let crossReferenceTree else { return nil }
        if crossReferenceTree.roots.isEmpty {
            let resultKind = crossReferenceTree.direction == .typeReferences ? "Type" : "Call"
            var text = "No \(resultKind) Results for “\(committedQuery?.term.plainText ?? "")”"
            if crossReferenceUnbuiltImageCount > 0 {
                text += " · \(crossReferenceUnbuiltImageCount) \(crossReferenceUnbuiltImageCount == 1 ? "image" : "images") not yet searchable"
            }
            return text
        }
        if let progress = crossReferenceLoadProgress, progress.totalImageCount > 0 {
            return "Scanning \(progress.scannedImageCount) of \(progress.totalImageCount) \(progress.totalImageCount == 1 ? "image" : "images")"
        }
        if truncatedCrossReferenceLevelCount > 0 {
            return "Some rows show only their first \(Self.crossReferenceResultLimit) references"
        }
        return nil
    }

    /// What a row whose level could not be loaded says.
    nonisolated static func crossReferenceFailureMessage(for error: any Swift.Error) -> String {
        if let requestError = error as? RuntimeNetworkRequestError, requestError.isUnknownCommand {
            return unsupportedBySourceSummary
        }
        return error.localizedDescription
    }

    // MARK: - Summary

    /// Publishes `newResults` as the answer to the query on screen.
    private func setResults(_ newResults: Results) {
        var stampedResults = newResults
        stampedResults.query = committedQuery
        results = stampedResults
        updateSummary()
    }

    private func updateSummary() {
        // Only a text or member search reads the corpora, and only those of
        // its scope; a relationship search or a failure has nothing to say
        // about them. The states are keyed as the engine keys an image, so
        // the scope is spelled that way too.
        let newSummary = Self.summary(
            of: results,
            corpusBuildStates: shownSearch == nil ? [:] : corpusBuildStates,
            within: shownSearch?.scopeImagePaths.map(canonicalImagePaths)
        )
        if newSummary != summary {
            summary = newSummary
        }
    }

    static func summary(of results: Results, corpusBuildStates: [String: RuntimeInterfaceCorpusBuildState], within scopeImagePaths: Set<String>? = nil) -> String? {
        guard var text = results.summary else { return nil }
        if results.omittedRepeatedMatchCount > 0 {
            text += " · " + foldedProtocolCopiesNotice(count: results.omittedRepeatedMatchCount)
        }
        if let corpusStatus = corpusStatus(of: corpusBuildStates, within: scopeImagePaths) {
            text += " · " + corpusStatus
        } else if !results.unbuiltImagePaths.isEmpty {
            let count = results.unbuiltImagePaths.count
            text += " · \(count) \(count == 1 ? "image" : "images") not yet searchable"
        }
        if results.stopReason == .regularExpressionTooExpensive {
            text += " · " + regularExpressionTooExpensiveNotice
        }
        return text
    }

    /// The summary bar for a search that failed. A peer that does not know
    /// the search commands — a RuntimeViewer older than Find on the other
    /// end — is not a failure to report but a source Find cannot serve.
    static func failureSummary(for error: any Swift.Error) -> String {
        if let requestError = error as? RuntimeNetworkRequestError, requestError.isUnknownCommand {
            return unsupportedBySourceSummary
        }
        return "Search failed: \(error.localizedDescription)"
    }

    /// `2 images being made searchable · building Foundation 37%`, counting
    /// the images of `scopeImagePaths` alone when it names some, or `nil`
    /// when no such image is waiting for its corpus.
    static func corpusStatus(of corpusBuildStates: [String: RuntimeInterfaceCorpusBuildState], within scopeImagePaths: Set<String>? = nil) -> String? {
        var statesInScope = corpusBuildStates
        if let scopeImagePaths {
            statesInScope = statesInScope.filter { scopeImagePaths.contains($0.key) }
        }
        let activeCount = statesInScope.values.filter(\.isActive).count
        guard activeCount > 0 else { return nil }
        var text = "\(activeCount) \(activeCount == 1 ? "image" : "images") being made searchable"
        let building = statesInScope
            .compactMap { imagePath, state -> (imagePath: String, progress: RuntimeInterfaceCorpusBuildProgress)? in
                guard case .building(let progress) = state else { return nil }
                return (imagePath, progress)
            }
            .min { $0.imagePath < $1.imagePath }
        if let building, building.progress.total > 0 {
            let imageName = FindScope.imageName(of: building.imagePath)
            text += " · building \(imageName) \(building.progress.built * 100 / building.progress.total)%"
        }
        return text
    }

    // MARK: - Grouping

    /// Hits or members grouped by the type they are in, in the order types
    /// first appeared; batches arrive per image, so a type's matches are
    /// contiguous.
    struct MatchGroups<Match: FindGroupedMatch> {
        private var matchesByObject: [RuntimeObjectKey: [Match]] = [:]
        private var order: [RuntimeObject] = []
        /// Each type's row, built once and kept until the type receives more
        /// matches. A batch holds one image's matches, so it builds rows for
        /// its own types only; every other row stays the instance the outline
        /// already shows, which its diff takes as unchanged at a glance.
        private var nodesByObject: [RuntimeObjectKey: FindResultNode] = [:]
        private(set) var matchCount = 0
        /// Matches collected by the search under way, for its interim count.
        private(set) var matchCountSinceLastFinish = 0

        var typeCount: Int { order.count }

        mutating func append(_ batch: [Match]) {
            for match in batch {
                if matchesByObject[match.object.key] == nil {
                    order.append(match.object)
                }
                matchesByObject[match.object.key, default: []].append(match)
                nodesByObject[match.object.key] = nil
                matchCount += 1
                matchCountSinceLastFinish += 1
            }
        }

        mutating func markFinished() {
            matchCountSinceLastFinish = 0
        }

        /// The rows, in the order types first appeared: the kept row of every
        /// type that received nothing since, and a new row for each that did.
        mutating func nodes() -> [FindResultNode] {
            var nodes: [FindResultNode] = []
            nodes.reserveCapacity(order.count)
            for object in order {
                if let node = nodesByObject[object.key] {
                    nodes.append(node)
                    continue
                }
                let matches = matchesByObject[object.key] ?? []
                let children = matches.enumerated().map { index, match in match.resultNode(index: index) }
                let node = FindResultNode.object(object, children: children)
                nodesByObject[object.key] = node
                nodes.append(node)
            }
            return nodes
        }
    }
}

/// A text hit or a member match, as the results tree groups it under the
/// type it is in. Internal, so the two conformances below are this module's
/// business alone.
protocol FindGroupedMatch {
    var object: RuntimeObject { get }

    /// The row the match makes under its type, the `index`th of them.
    func resultNode(index: Int) -> FindResultNode
}

extension RuntimeInterfaceSearchMatch: FindGroupedMatch {
    func resultNode(index: Int) -> FindResultNode {
        .textMatch(self, index: index)
    }
}

extension RuntimeMemberMatch: FindGroupedMatch {
    func resultNode(index: Int) -> FindResultNode {
        .member(self, index: index)
    }
}
