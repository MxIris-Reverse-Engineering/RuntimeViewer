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
@MainActor
@Loggable(.private)
public final class FindSession {
    /// The results tree and the words above it, published together so the
    /// outline and the summary bar never disagree.
    public struct Results: Equatable {
        public var nodes: [FindResultNode] = []
        /// `N results in M types`, or `nil` while there is nothing to say —
        /// the summary bar is absent then, as in Xcode.
        public var summary: String?
        /// Images the search did not see because their corpus is not built.
        public var unbuiltImagePaths: [String] = []
        public var isTruncated = false

        public init() {}
    }

    public unowned let documentState: DocumentState

    @RxObserved
    public private(set) var query: FindQuery = FindQuery()

    @RxObserved
    public private(set) var results: Results = Results()

    @RxObserved
    public private(set) var isSearching: Bool = false

    /// Fired when a page should take the keyboard focus into its search
    /// field — Edit ▸ Find ▸ Find in Indexed Images.
    public let focusSearchFieldRelay = PublishRelay<Void>()

    private var searchTask: Task<Void, Never>?

    /// Bumped per `run`; a finishing search only clears `isSearching` when
    /// it is still the current one.
    private var searchGeneration = 0

    private var textMatchGroups = TextMatchGroups()

    private var memberMatchGroups = MemberMatchGroups()

    public init(documentState: DocumentState) {
        self.documentState = documentState
    }

    deinit {
        searchTask?.cancel()
    }

    // MARK: - Query

    /// Changes the query without searching; the next `run` uses it. The
    /// mode path and the case toggle call this.
    public func update(_ change: (inout FindQuery) -> Void) {
        var updated = query
        change(&updated)
        guard updated != query else { return }
        query = updated
    }

    /// Runs `query` (Return in the search field). An empty query clears the
    /// results instead.
    public func run(_ query: FindQuery) {
        self.query = query
        searchTask?.cancel()
        searchTask = nil
        guard !query.isEmpty else {
            results = Results()
            isSearching = false
            return
        }
        results = Results()
        textMatchGroups = TextMatchGroups()
        memberMatchGroups = MemberMatchGroups()
        isSearching = true
        searchGeneration += 1
        let generation = searchGeneration
        let engine = documentState.runtimeEngine
        searchTask = Task { [weak self] in
            do {
                try await self?.perform(query, on: engine)
            } catch is CancellationError {
                // Superseded; the newer search owns the results now.
            } catch {
                #log(.error, "Find failed: \(error, privacy: .public)")
                guard let self, self.searchGeneration == generation else { return }
                var failed = Results()
                failed.summary = "Search failed: \(error.localizedDescription)"
                self.results = failed
            }
            guard let self, self.searchGeneration == generation else { return }
            self.isSearching = false
        }
    }

    /// Runs the query in force again — after the corpus grew, say.
    public func rerun() {
        run(query)
    }

    public func clear() {
        run(FindQuery(mode: query.mode, text: "", textMatchStyle: query.textMatchStyle, memberKindFilter: query.memberKindFilter, isCaseSensitive: query.isCaseSensitive))
    }

    // MARK: - Execution

    private func perform(_ query: FindQuery, on engine: RuntimeEngine) async throws {
        switch query.mode {
        case .text, .regularExpression:
            let engineQuery = RuntimeInterfaceSearchQuery(
                text: query.trimmedText,
                matchMode: query.mode == .regularExpression ? .regularExpression : query.textMatchStyle.matchMode,
                isCaseSensitive: query.isCaseSensitive,
                scope: .all
            )
            let summary = try await engine.searchInterfaces(engineQuery) { [weak self] batch in
                await self?.appendTextMatches(batch)
            }
            try Task.checkCancellation()
            results = Self.results(from: textMatchGroups.nodes(), matchCount: summary.totalMatchCount, typeCount: textMatchGroups.typeCount, summary: summary)
        case .members:
            let engineQuery = RuntimeMemberSearchQuery(
                text: query.trimmedText,
                kinds: query.memberKindFilter.kinds,
                isCaseSensitive: query.isCaseSensitive
            )
            let summary = try await engine.searchMembers(engineQuery) { [weak self] batch in
                await self?.appendMemberMatches(batch)
            }
            try Task.checkCancellation()
            results = Self.results(from: memberMatchGroups.nodes(), matchCount: summary.totalMatchCount, typeCount: memberMatchGroups.typeCount, summary: summary)
        case .ancestorTypes, .descendantTypes, .conformingTypes:
            let relationship = query.mode.relationship ?? .ancestors
            let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: query.trimmedText, relationship: relationship, isCaseSensitive: query.isCaseSensitive))
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
            results = relationshipResults
        }
    }

    /// One image's batch, folded into the tree while the search goes on.
    private func appendTextMatches(_ batch: [RuntimeInterfaceSearchMatch]) {
        textMatchGroups.append(batch)
        results = Self.results(from: textMatchGroups.nodes(), matchCount: textMatchGroups.matchCount, typeCount: textMatchGroups.typeCount, summary: nil)
    }

    private func appendMemberMatches(_ batch: [RuntimeMemberMatch]) {
        memberMatchGroups.append(batch)
        results = Self.results(from: memberMatchGroups.nodes(), matchCount: memberMatchGroups.matchCount, typeCount: memberMatchGroups.typeCount, summary: nil)
    }

    private static func count(_ nodes: [FindResultNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + count($1.children) }
    }

    private static func results(from nodes: [FindResultNode], matchCount: Int, typeCount: Int, summary: RuntimeInterfaceSearchSummary?) -> Results {
        var results = Results()
        results.nodes = nodes
        var text = "\(matchCount) \(matchCount == 1 ? "result" : "results") in \(typeCount) \(typeCount == 1 ? "type" : "types")"
        if let summary {
            if summary.isTruncated {
                text += ", showing the first \(nodes.reduce(0) { $0 + $1.children.count })"
            }
            results.unbuiltImagePaths = summary.unbuiltIndexedImagePaths
            results.isTruncated = summary.isTruncated
            if !summary.unbuiltIndexedImagePaths.isEmpty {
                let count = summary.unbuiltIndexedImagePaths.count
                text += " · \(count) \(count == 1 ? "image" : "images") not yet searchable"
            }
        }
        results.summary = text
        return results
    }

    // MARK: - Grouping

    /// Hits grouped by the type they are in, in the order types first
    /// appeared; batches arrive per image, so a type's hits are contiguous.
    private struct TextMatchGroups {
        private var matchesByObject: [RuntimeObjectKey: [RuntimeInterfaceSearchMatch]] = [:]
        private var order: [RuntimeObject] = []
        private(set) var matchCount = 0

        var typeCount: Int { order.count }

        mutating func append(_ batch: [RuntimeInterfaceSearchMatch]) {
            for match in batch {
                if matchesByObject[match.object.key] == nil {
                    order.append(match.object)
                }
                matchesByObject[match.object.key, default: []].append(match)
                matchCount += 1
            }
        }

        func nodes() -> [FindResultNode] {
            order.map { object in
                let matches = matchesByObject[object.key] ?? []
                let children = matches.enumerated().map { index, match in FindResultNode.textMatch(match, index: index) }
                return FindResultNode.object(object, matchCount: matches.count, children: children)
            }
        }
    }

    private struct MemberMatchGroups {
        private var matchesByObject: [RuntimeObjectKey: [RuntimeMemberMatch]] = [:]
        private var order: [RuntimeObject] = []
        private(set) var matchCount = 0

        var typeCount: Int { order.count }

        mutating func append(_ batch: [RuntimeMemberMatch]) {
            for match in batch {
                if matchesByObject[match.object.key] == nil {
                    order.append(match.object)
                }
                matchesByObject[match.object.key, default: []].append(match)
                matchCount += 1
            }
        }

        func nodes() -> [FindResultNode] {
            order.map { object in
                let matches = matchesByObject[object.key] ?? []
                let children = matches.enumerated().map { index, match in FindResultNode.member(match, index: index) }
                return FindResultNode.object(object, matchCount: matches.count, children: children)
            }
        }
    }
}
