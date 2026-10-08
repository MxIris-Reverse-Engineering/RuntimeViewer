import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures

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
        /// The query these results answer: the one last run, not the one
        /// the mode path and the toggles may have been edited into since. A
        /// click highlights with its mode and case. `nil` with nothing
        /// searched.
        public internal(set) var query: FindQuery?

        public init() {}
    }

    /// The most hits or members a search collects, across every image it
    /// reads; the count goes on past it.
    static let resultLimit = 1000

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

    /// The coordinator `follow(_:)` hooked the session to; it moves the
    /// images in scope to the front of its queue. `nil` until it exists, and
    /// the session never brings it into being itself.
    private weak var corpusCoordinator: FindCorpusCoordinator?

    @Dependency(\.appDefaults)
    private var appDefaults

    /// Replaced when the document closes, which ends every subscription.
    private var disposeBag = DisposeBag()

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
            // One turn later. The page's view model brings this session into
            // being before the corpus coordinator exists, so the coordinator
            // hears of the reset after this subscriber does; searching at
            // once would put the scope's images at the front of a queue the
            // coordinator is about to withdraw.
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
    }

    /// Hooks the session to the document's corpus coordinator, which calls
    /// this once it exists: its build states feed the summary bar, and each
    /// corpus it reports built is read by the search in force. Once every
    /// corpus is dropped to be printed with a new transformer, that search
    /// runs again: the images rebuilt are ones it has already read.
    func follow(_ corpusCoordinator: FindCorpusCoordinator) {
        self.corpusCoordinator = corpusCoordinator
        corpusCoordinator.$buildStatesByImagePath.asDriver()
            .driveOnNextMainActor { [weak self] states in
                guard let self else { return }
                self.corpusBuildStates = states
                self.updateSummary()
            }
            .disposed(by: disposeBag)
        corpusCoordinator.corpusBuilt
            .emitOnNextMainActor { [weak self] imagePath in
                guard let self else { return }
                self.corpusDidBuild(at: imagePath)
            }
            .disposed(by: disposeBag)
        corpusCoordinator.corporaRebuilt
            .emitOnNextMainActor { [weak self] in
                guard let self else { return }
                self.rerunShownSearch()
            }
            .disposed(by: disposeBag)
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
        let scopeImagePaths = imagePaths(of: query.scope)
        if scopeImagePaths?.isEmpty == true {
            isSearching = false
            var nothingToSearch = Results()
            nothingToSearch.summary = "No current image"
            setResults(nothingToSearch)
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
        imagePathsBuiltDuringSearch = []
        textMatchGroups = MatchGroups<RuntimeInterfaceSearchMatch>()
        memberMatchGroups = MatchGroups<RuntimeMemberMatch>()
        setResults(Results())
    }

    public func clear() {
        var cleared = query
        cleared.text = ""
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
                        await self?.appendTextMatches(batch, from: run)
                    }
                    outcome = .success(.text(summary))
                case .members(let engineQuery):
                    let summary = try await engine.searchMembers(engineQuery) { [weak self] batch in
                        await self?.appendMemberMatches(batch, from: run)
                    }
                    outcome = .success(.members(summary))
                case .relationships(let engineQuery):
                    outcome = .success(.relationships(try await engine.typeRelationships(engineQuery)))
                }
            } catch {
                outcome = .failure(error)
            }
            self?.runDidEnd(run, with: outcome, isWidening: isWidening)
        }
    }

    private func searchRequest(for query: FindQuery, imagePaths: Set<String>?, generationOptions: RuntimeObjectInterface.GenerationOptions) -> SearchRequest {
        switch query.mode {
        case .text, .regularExpression:
            .text(RuntimeInterfaceSearchQuery(
                text: query.trimmedText,
                matchMode: query.mode == .regularExpression ? .regularExpression : query.textMatchStyle.matchMode,
                isCaseSensitive: query.isCaseSensitive,
                scope: .all,
                resultLimit: max(0, Self.resultLimit - textMatchGroups.matchCount),
                generationOptions: generationOptions,
                imagePaths: imagePaths
            ))
        case .members:
            .members(RuntimeMemberSearchQuery(
                text: query.trimmedText,
                matchMode: query.memberMatchStyle.matchMode,
                kinds: query.memberKindFilter.kinds,
                isCaseSensitive: query.isCaseSensitive,
                resultLimit: max(0, Self.resultLimit - memberMatchGroups.matchCount),
                generationOptions: generationOptions,
                imagePaths: imagePaths
            ))
        case .ancestorTypes, .descendantTypes, .conformingTypes:
            .relationships(RuntimeTypeRelationshipsQuery(
                text: query.trimmedText,
                matchMode: query.textMatchStyle.matchMode,
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
                failed.summary = "Search failed: \(error.localizedDescription)"
                setResults(failed)
            }
        }
        isSearching = false
        searchImagesBuiltDuringSearch()
    }

    /// Stops the engine call under way and stops listening to it: whatever it
    /// still delivers is dropped.
    private func cancelCurrentRun() {
        searchTask?.cancel()
        searchTask = nil
        currentRun = nil
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
            nodes.append(FindResultNode.object(tree.root, matchCount: children.count, children: children))
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
        shownSearch.isTruncated = shownSearch.isTruncated || summary.isTruncated
        self.shownSearch = shownSearch
        var finished = results(from: nodes, matchCount: shownSearch.totalMatchCount, typeCount: typeCount)
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
        updated.unbuiltImagePaths = results.unbuiltImagePaths
        var text = "\(matchCount) \(matchCount == 1 ? "result" : "results") in \(typeCount) \(typeCount == 1 ? "type" : "types")"
        if updated.isTruncated {
            text += ", showing the first \(nodes.reduce(0) { $0 + $1.children.count })"
        }
        updated.summary = text
        return updated
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
        if let corpusStatus = corpusStatus(of: corpusBuildStates, within: scopeImagePaths) {
            text += " · " + corpusStatus
        } else if !results.unbuiltImagePaths.isEmpty {
            let count = results.unbuiltImagePaths.count
            text += " · \(count) \(count == 1 ? "image" : "images") not yet searchable"
        }
        return text
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
            let imageName = (building.imagePath as NSString).lastPathComponent
            text += " · building \(imageName) \(building.progress.built * 100 / building.progress.total)%"
        }
        return text
    }

    // MARK: - Grouping

    /// Hits or members grouped by the type they are in, in the order types
    /// first appeared; batches arrive per image, so a type's matches are
    /// contiguous.
    private struct MatchGroups<Match: FindGroupedMatch> {
        private var matchesByObject: [RuntimeObjectKey: [Match]] = [:]
        private var order: [RuntimeObject] = []
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
                matchCount += 1
                matchCountSinceLastFinish += 1
            }
        }

        mutating func markFinished() {
            matchCountSinceLastFinish = 0
        }

        func nodes() -> [FindResultNode] {
            order.map { object in
                let matches = matchesByObject[object.key] ?? []
                let children = matches.enumerated().map { index, match in match.resultNode(index: index) }
                return FindResultNode.object(object, matchCount: matches.count, children: children)
            }
        }
    }
}

/// A text hit or a member match, as the results tree groups it under the
/// type it is in. Private to this file, so the two conformances below are
/// this module's business alone.
private protocol FindGroupedMatch {
    var object: RuntimeObject { get }

    /// The row the match makes under its type, the `index`th of them.
    func resultNode(index: Int) -> FindResultNode
}

extension RuntimeInterfaceSearchMatch: FindGroupedMatch {
    fileprivate func resultNode(index: Int) -> FindResultNode {
        .textMatch(self, index: index)
    }
}

extension RuntimeMemberMatch: FindGroupedMatch {
    fileprivate func resultNode(index: Int) -> FindResultNode {
        .member(self, index: index)
    }
}
