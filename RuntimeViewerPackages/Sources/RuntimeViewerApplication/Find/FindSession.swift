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
/// answer in one piece. A new search cancels the one in flight.
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

        public init() {}
    }

    /// The most hits or members a search collects, across every image it
    /// reads; the count goes on past it.
    static let resultLimit = 1000

    /// Weak: the session can outlive its document. An engine call over a
    /// connection runs to its answer even when cancelled, and until it does a
    /// closed window's session is still alive — and still subscribed to the
    /// Generation Options every window shares.
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

    private var searchTask: Task<Void, Never>?

    /// Bumped per search; a finishing search only clears `isSearching` when
    /// it is still the current one.
    private var searchGeneration = 0

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
                    self.rerunAfterGenerationOptionsChange()
                }
            }
            .disposed(by: disposeBag)
    }

    deinit {
        searchTask?.cancel()
    }

    /// The document is closing. The search under way is cancelled, and nothing
    /// starts another one: not a Generation Options change made in another
    /// window, not a corpus the coordinator reports built.
    public func documentWillClose() {
        searchTask?.cancel()
        searchTask = nil
        // A search still finishing compares its generation with this one and
        // leaves the session alone.
        searchGeneration += 1
        isSearching = false
        disposeBag = DisposeBag()
    }

    /// Hooks the session to the document's corpus coordinator, which calls
    /// this once it exists: its build states feed the summary bar, and each
    /// corpus it reports built is read by the search in force.
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
        searchTask?.cancel()
        searchTask = nil
        shownSearch = nil
        imagePathsBuiltDuringSearch = []
        textMatchGroups = MatchGroups<RuntimeInterfaceSearchMatch>()
        memberMatchGroups = MatchGroups<RuntimeMemberMatch>()
        setResults(Results())
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

    /// A text or member search already shown answers for the options it ran
    /// under; run it again so it answers for the ones the content pane now
    /// displays with. Relationship searches do not depend on them.
    private func rerunAfterGenerationOptionsChange() {
        guard !query.isEmpty, query.mode.relationship == nil, results.summary != nil || isSearching else { return }
        run(query)
    }

    public func clear() {
        var cleared = query
        cleared.text = ""
        run(cleared)
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
        for imagePath in scopeImagePaths.sorted() where corpusBuildStates[imagePath]?.isBuilt != true {
            corpusCoordinator.requestBuild(of: imagePath, isPrioritized: true)
        }
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

    /// Runs `query` over `imagePaths` — every built image when `nil` — and
    /// folds what it finds into the results. A search that widens one already
    /// shown keeps the results it is merged into when it fails.
    private func startSearch(_ query: FindQuery, imagePaths: Set<String>?, generationOptions: RuntimeObjectInterface.GenerationOptions, isWidening: Bool) {
        // Closed while an engine call kept this session alive: there is no
        // document to search for any more.
        guard let engine = documentState?.runtimeEngine else {
            isSearching = false
            return
        }
        isSearching = true
        searchGeneration += 1
        let generation = searchGeneration
        searchTask = Task { [weak self] in
            do {
                try await self?.perform(query, imagePaths: imagePaths, generationOptions: generationOptions, isWidening: isWidening, on: engine)
            } catch is CancellationError {
                // Superseded; the newer search owns the results now.
            } catch {
                #log(.error, "Find failed: \(error, privacy: .public)")
                guard let self, self.searchGeneration == generation, !isWidening else { return }
                self.shownSearch = nil
                var failed = Results()
                failed.summary = "Search failed: \(error.localizedDescription)"
                self.setResults(failed)
            }
            guard let self, self.searchGeneration == generation else { return }
            self.isSearching = false
            self.searchImagesBuiltDuringSearch()
        }
    }

    private func perform(_ query: FindQuery, imagePaths: Set<String>?, generationOptions: RuntimeObjectInterface.GenerationOptions, isWidening: Bool, on engine: RuntimeEngine) async throws {
        switch query.mode {
        case .text, .regularExpression:
            let engineQuery = RuntimeInterfaceSearchQuery(
                text: query.trimmedText,
                matchMode: query.mode == .regularExpression ? .regularExpression : query.textMatchStyle.matchMode,
                isCaseSensitive: query.isCaseSensitive,
                scope: .all,
                resultLimit: max(0, Self.resultLimit - textMatchGroups.matchCount),
                generationOptions: generationOptions,
                imagePaths: imagePaths
            )
            let summary = try await engine.searchInterfaces(engineQuery) { [weak self] batch in
                await self?.appendTextMatches(batch)
            }
            try Task.checkCancellation()
            finish(with: summary, nodes: textMatchGroups.nodes(), typeCount: textMatchGroups.typeCount, isWidening: isWidening)
        case .members:
            let engineQuery = RuntimeMemberSearchQuery(
                text: query.trimmedText,
                matchMode: query.memberMatchStyle.matchMode,
                kinds: query.memberKindFilter.kinds,
                isCaseSensitive: query.isCaseSensitive,
                resultLimit: max(0, Self.resultLimit - memberMatchGroups.matchCount),
                generationOptions: generationOptions,
                imagePaths: imagePaths
            )
            let summary = try await engine.searchMembers(engineQuery) { [weak self] batch in
                await self?.appendMemberMatches(batch)
            }
            try Task.checkCancellation()
            finish(with: summary, nodes: memberMatchGroups.nodes(), typeCount: memberMatchGroups.typeCount, isWidening: isWidening)
        case .ancestorTypes, .descendantTypes, .conformingTypes:
            let relationship = query.mode.relationship ?? .ancestors
            let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: query.trimmedText, matchMode: query.textMatchStyle.matchMode, relationship: relationship, isCaseSensitive: query.isCaseSensitive, imagePaths: imagePaths))
            try Task.checkCancellation()
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
    }

    /// One image's batch, folded into the tree while the search goes on.
    private func appendTextMatches(_ batch: [RuntimeInterfaceSearchMatch]) {
        textMatchGroups.append(batch)
        setResults(results(from: textMatchGroups.nodes(), matchCount: (shownSearch?.totalMatchCount ?? 0) + textMatchGroups.matchCountSinceLastFinish, typeCount: textMatchGroups.typeCount))
    }

    private func appendMemberMatches(_ batch: [RuntimeMemberMatch]) {
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
    }

    /// A corpus the coordinator reports built is read by the search on
    /// screen, unless it already was; a search still running reads it once
    /// it ends.
    private func corpusDidBuild(at imagePath: String) {
        guard shownSearch != nil else { return }
        imagePathsBuiltDuringSearch.insert(imagePath)
        guard !isSearching else { return }
        searchImagesBuiltDuringSearch()
    }

    private func searchImagesBuiltDuringSearch() {
        let imagePaths = imagePathsBuiltDuringSearch
        imagePathsBuiltDuringSearch = []
        guard let shownSearch else { return }
        var unsearchedImagePaths = imagePaths.subtracting(shownSearch.searchedImagePaths)
        if let scopeImagePaths = shownSearch.scopeImagePaths {
            unsearchedImagePaths.formIntersection(scopeImagePaths)
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

    private func setResults(_ newResults: Results) {
        results = newResults
        updateSummary()
    }

    private func updateSummary() {
        // Only a text or member search reads the corpora, and only those of
        // its scope; a relationship search or a failure has nothing to say
        // about them.
        let newSummary = Self.summary(of: results, corpusBuildStates: shownSearch == nil ? [:] : corpusBuildStates, within: shownSearch?.scopeImagePaths)
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
