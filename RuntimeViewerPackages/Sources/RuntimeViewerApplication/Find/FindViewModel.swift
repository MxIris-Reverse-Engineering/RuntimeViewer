import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

/// One Find navigator page. Generic over the sidebar level's route because
/// the page is a tab of both sidebar levels; the state lives in the
/// document's `FindSession`, which both pages bind to, and the scope chooser
/// is presented by whichever level the page is on.
public final class FindViewModel<Route: FindNavigatorRoutable>: ViewModel<Route> {
    /// Every input that writes the query is an event, never a state with an initial value. Both
    /// sidebar levels have a page bound to the document's one `FindSession`, and a value a page
    /// replays as it binds — its controls' defaults — would overwrite the query the other page
    /// set. Read a control's state when it is clicked (`rx.click(with:)`), not through a
    /// property that may start with a value under some overloads.
    @MemberwiseInit(.public)
    public struct Input {
        /// A choice made in one of the mode path's menus.
        public let modePathChoiceSelected: Signal<FindModePathChoice>
        public let memberKindFilterSelected: Signal<FindMemberKindFilter>
        public let caseSensitiveToggled: Signal<Bool>
        /// A choice made in the scope button's menu.
        public let scopeMenuChoiceSelected: Signal<FindScopeMenuChoice>
        /// Return in the search field: what it holds.
        public let searchCommitted: Signal<FindQueryTerm>
        /// A recent query chosen from the search field's menu, to run as it was.
        public let recentQuerySelected: Signal<FindQuery>
        /// Clear Recents chosen from the search field's menu.
        public let clearRecentQueriesSelected: Signal<Void>
        /// The bottom filter bar, as typed.
        public let filterString: Driver<String>
        /// The row the user chose, to open in place.
        public let resultClicked: Signal<FindResultNode>
        public let resultOpenedInNewTab: Signal<FindResultNode>
        /// Rows the outline collapsed or expanded.
        public let resultCollapsed: Signal<FindResultNode>
        public let resultExpanded: Signal<FindResultNode>
        /// The rows the user selected — by click, arrow key or type-select — never a selection
        /// the outline put back after its rows changed.
        public let resultsSelected: Signal<[FindResultNode]>
    }

    public struct Output {
        public let query: Driver<FindQuery>
        /// `Find ▸ Text ▸ Containing`: the components the mode path shows for the query.
        public let modePath: Driver<[FindModePathComponent]>
        /// `In Indexed Images`, `In Current Image`, `In Foundation`, `In 3 Images`.
        public let scopeTitle: Driver<String>
        /// Whether the scope button draws its title in the accent colour.
        public let isScopeAccented: Driver<Bool>
        /// The images a scope names, or what the sidebar lists for the current
        /// image; `nil` for every indexed image.
        public let scopeToolTip: Driver<String?>
        /// The scope button's menu, as it is now. The page builds the menu
        /// from the latest value each time it opens, as Xcode rebuilds its own.
        public let scopeMenuItems: Driver<[FindScopeMenuItem]>
        public let searchFieldPlaceholder: Driver<String>
        /// Whether find patterns can be inserted into the search field: in Text mode alone.
        public let allowsPatternInsertion: Driver<Bool>
        /// The recent queries of the document's source, most recent first, for the search field's
        /// menu.
        public let recentQueries: Driver<[FindQuery]>
        public let nodes: Driver<[FindResultNode]>
        /// `nodes` with what to expand and select once the outline has them; drives the outline.
        public let presentation: Driver<FindResultsPresentation>
        /// `nil` hides the summary bar.
        public let summary: Driver<String?>
        public let isSearching: Driver<Bool>
        public let focusSearchField: Signal<Void>
    }

    private let session: FindSession

    @RxObserved
    private var filterString: String = ""

    /// Rows the user collapsed during the search on screen, by identifier; every other row with
    /// children shows expanded. Read when the rows change, never observed.
    private var collapsedResultIdentifiers: Set<String> = []

    /// The rows the user selected, by identifier, put back on the same rows when an update moves
    /// them. Read when the rows change, never observed.
    private var selectedResultIdentifiers: Set<String> = []

    /// The row the last navigation from this page went to, by identifier.
    private var lastNavigatedResultIdentifier: String?

    public override init(documentState: DocumentState, router: any Router<Route>) {
        self.session = documentState.findSession
        super.init(documentState: documentState, router: router)
    }

    public func transform(_ input: Input) -> Output {
        input.modePathChoiceSelected.emitOnNext { [session] choice in
            session.update { choice.apply(to: &$0) }
        }
        .disposed(by: rx.disposeBag)

        input.memberKindFilterSelected.emitOnNext { [session] filter in
            session.update { $0.memberKindFilter = filter }
        }
        .disposed(by: rx.disposeBag)

        input.caseSensitiveToggled.emitOnNext { [session] isCaseSensitive in
            session.update { $0.isCaseSensitive = isCaseSensitive }
        }
        .disposed(by: rx.disposeBag)

        input.scopeMenuChoiceSelected.emitOnNext { [weak self] choice in
            guard let self else { return }
            choose(choice)
        }
        .disposed(by: rx.disposeBag)

        input.searchCommitted.emitOnNext { [weak self] term in
            guard let self else { return }
            var query = session.query
            query.term = term
            run(query)
        }
        .disposed(by: rx.disposeBag)

        // `-userDidSelectHistoricQuery:`: the whole query comes back — mode, term, match style,
        // member kinds, case and scope — and runs at once.
        input.recentQuerySelected.emitOnNext { [weak self] recentQuery in
            guard let self else { return }
            run(recentQuery)
        }
        .disposed(by: rx.disposeBag)

        input.clearRecentQueriesSelected.emitOnNext { [weak self] in
            guard let self else { return }
            appDefaults.findRecentQueriesByScope[recentQueriesKey] = nil
        }
        .disposed(by: rx.disposeBag)

        input.filterString.driveOnNext { [weak self] filterString in
            guard let self else { return }
            self.filterString = filterString
        }
        .disposed(by: rx.disposeBag)

        input.resultClicked.emitOnNext { [weak self] node in
            guard let self else { return }
            // The row whose type the document still shows because of it — the second click of a
            // double-click, or the same row clicked again — is not navigated to again: that would
            // only scroll back and flash once more. Once the document shows something else, the
            // row navigates back to it.
            guard !isShowingNavigation(to: node) else { return }
            navigate(to: node, inNewTab: false)
        }
        .disposed(by: rx.disposeBag)

        input.resultOpenedInNewTab.emitOnNext { [weak self] node in
            guard let self else { return }
            navigate(to: node, inNewTab: true)
        }
        .disposed(by: rx.disposeBag)

        input.resultCollapsed.emitOnNext { [weak self] node in
            guard let self else { return }
            collapsedResultIdentifiers.insert(node.identifier)
        }
        .disposed(by: rx.disposeBag)

        input.resultExpanded.emitOnNext { [weak self] node in
            guard let self else { return }
            collapsedResultIdentifiers.remove(node.identifier)
        }
        .disposed(by: rx.disposeBag)

        input.resultsSelected.emitOnNext { [weak self] nodes in
            guard let self else { return }
            selectedResultIdentifiers = Set(nodes.map(\.identifier))
        }
        .disposed(by: rx.disposeBag)

        // A new search starts with every row expanded and nothing selected: whatever starts one —
        // Return, a cleared field, an engine switch, a rerun under other Generation Options —
        // publishes empty results before anything else.
        session.$results.asDriver()
            .filter(\.nodes.isEmpty)
            .driveOnNext { [weak self] _ in
                guard let self else { return }
                collapsedResultIdentifiers = []
                selectedResultIdentifiers = []
                lastNavigatedResultIdentifier = nil
            }
            .disposed(by: rx.disposeBag)

        let filteredResults = Driver.combineLatest(session.$results.asDriver(), $filterString.asDriver()) { results, filterString in
            (nodes: Self.filtered(results.nodes, by: filterString), isRelationshipTree: results.query?.mode.relationship != nil)
        }
        let nodes = filteredResults.map(\.nodes)
        let presentation = filteredResults.map { [weak self] filteredResults -> FindResultsPresentation in
            guard let self else {
                return FindResultsPresentation(nodes: filteredResults.nodes, nodesToExpand: [], nodesToSelect: [])
            }
            return FindResultsPresentation(
                nodes: filteredResults.nodes,
                nodesToExpand: FindResultsOutline.nodesToExpand(in: filteredResults.nodes, collapsedIdentifiers: collapsedResultIdentifiers, isRelationshipTree: filteredResults.isRelationshipTree),
                nodesToSelect: FindResultsOutline.nodes(in: filteredResults.nodes, identifiedBy: selectedResultIdentifiers)
            )
        }

        let scope = session.$query.asDriver().map(\.scope).distinctUntilChanged()
        let currentImagePath = documentState.$currentImageNode.asDriver().map { $0?.path }
        let scopeToolTip = Driver.combineLatest(scope, currentImagePath) { scope, currentImagePath in
            Self.toolTip(for: scope, currentImagePath: currentImagePath)
        }
        let scopeMenuItems = Driver.combineLatest(scope, currentImagePath, nodes.map { !$0.isEmpty }.distinctUntilChanged()) { scope, currentImagePath, hasVisibleResults in
            FindScopeMenuItem.menu(for: scope, currentImagePath: currentImagePath, hasVisibleResults: hasVisibleResults)
        }
        .distinctUntilChanged()

        // The source's own list: another source's scopes name images this one may not have.
        let recentQueries = Driver.combineLatest(
            appDefaults.$findRecentQueriesByScope.asDriver(onErrorJustReturn: [:]),
            documentState.$runtimeEngine.asDriver()
        ) { recentQueriesByScope, runtimeEngine in
            recentQueriesByScope[runtimeEngine.bookmarkScope.bookmarkKey] ?? []
        }
        .distinctUntilChanged()

        return Output(
            query: session.$query.asDriver(),
            modePath: session.$query.asDriver().map(FindModePathComponent.path(for:)).distinctUntilChanged(),
            scopeTitle: scope.map(\.title),
            isScopeAccented: scope.map(\.isAccented),
            scopeToolTip: scopeToolTip,
            scopeMenuItems: scopeMenuItems,
            searchFieldPlaceholder: session.$query.asDriver().map(\.mode.searchFieldPlaceholder),
            allowsPatternInsertion: session.$query.asDriver().map(\.mode.supportsPatterns).distinctUntilChanged(),
            recentQueries: recentQueries,
            nodes: nodes,
            presentation: presentation,
            summary: session.$summary.asDriver(),
            isSearching: session.$isSearching.asDriver(),
            focusSearchField: session.focusSearchFieldRelay.asSignal()
        )
    }

    // MARK: - Running

    /// Runs `query` as the user asked for it, and records it among the recent queries
    /// (`-[IDEFindNavigatorQueryParametersController initiateQuery]`). A search that runs again by
    /// itself goes through the session alone and is not recorded.
    private func run(_ query: FindQuery) {
        session.run(query)
        guard !query.isEmpty else { return }
        let key = recentQueriesKey
        appDefaults.findRecentQueriesByScope[key] = FindRecentQueries.recording(query, in: appDefaults.findRecentQueriesByScope[key] ?? [])
    }

    /// Where the recent queries of the document's source are kept: the key its bookmarks are under.
    private var recentQueriesKey: String {
        documentState.runtimeEngine.bookmarkScope.bookmarkKey
    }

    // MARK: - Scope

    /// A choice from the scope menu: a scope, which is an edit of the query
    /// like the mode path's choices — Return searches — or the chooser.
    private func choose(_ choice: FindScopeMenuChoice) {
        switch choice {
        case .allIndexedImages:
            session.update { $0.scope = .allIndexedImages }
        case .currentImage:
            guard documentState.currentImageNode != nil else { return }
            session.update { $0.scope = .currentImage }
        case .currentFindResults:
            // The rows on screen, after the filter bar, as Xcode's
            // `-[IDEFindNavigatorQueryParametersController documentURLsForSubsearch]`
            // reads `allVisibleResults`.
            let imagePaths = Self.imagePaths(in: Self.filtered(session.results.nodes, by: filterString))
            guard !imagePaths.isEmpty else { return }
            session.update { $0.scope = .images(imagePaths) }
        case .customScopes:
            router.trigger(.findScopeChooser)
        }
    }

    /// The images the rows come from, at every level: a type's, a hit's or a
    /// member's object, and every resolved node of a relationship tree.
    static func imagePaths(in nodes: [FindResultNode]) -> Set<String> {
        var imagePaths: Set<String> = []
        func collect(_ nodes: [FindResultNode]) {
            for node in nodes {
                if let imagePath = node.navigationTarget?.imagePath {
                    imagePaths.insert(imagePath)
                }
                collect(node.children)
            }
        }
        collect(nodes)
        return imagePaths
    }

    /// The scope button's tool tip: the names of the images a scope picks,
    /// one per line, or the image the sidebar lists; nothing for every
    /// indexed image, which the title already says.
    static func toolTip(for scope: FindScope, currentImagePath: String?) -> String? {
        switch scope {
        case .allIndexedImages:
            return nil
        case .currentImage:
            return currentImagePath.map(FindScope.imageName(of:)) ?? "No image is open in the sidebar"
        case .images(let imagePaths):
            return imagePaths
                .map(FindScope.imageName(of:))
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .joined(separator: "\n")
        }
    }

    // MARK: - Navigation

    /// Whether the last navigation from this page went to `node`, and the document shows its
    /// type still.
    private func isShowingNavigation(to node: FindResultNode) -> Bool {
        guard node.identifier == lastNavigatedResultIdentifier, let object = node.navigationTarget else { return false }
        return documentState.selectedRuntimeObject == object
    }

    private func navigate(to node: FindResultNode, inNewTab: Bool) {
        guard let object = node.navigationTarget else { return }
        lastNavigatedResultIdentifier = node.identifier
        // The query the rows answer, not the one the mode path and the
        // toggles may have been edited into since.
        let highlight = Self.highlight(for: node, query: session.results.query ?? session.query)
        switch (inNewTab, highlight) {
        case (false, nil):
            documentState.selectionRouter.trigger(.push(object))
        case (false, let highlight?):
            documentState.selectionRouter.trigger(.pushHighlighting(object, highlight))
        case (true, nil):
            documentState.selectionRouter.trigger(.openInNewTab(object))
        case (true, let highlight?):
            documentState.selectionRouter.trigger(.openInNewTabHighlighting(object, highlight))
        }
    }

    /// Where in the object's interface a hit or member sits, for the content
    /// pane to scroll to; type rows and relationship rows carry no place. A
    /// hit is found again with what the search sent the engine, the regular
    /// expression of a query with patterns included.
    private static func highlight(for node: FindResultNode, query: FindQuery) -> ContentHighlightRequest? {
        switch node.content {
        case .textMatch(let match):
            let searchText = query.textSearchText
            return ContentHighlightRequest(
                lineNumber: match.lineNumber,
                lineText: match.lineText,
                matchRangeInLine: match.matchRangeInLine,
                query: searchText.text,
                matchMode: searchText.matchMode,
                isCaseSensitive: query.isCaseSensitive
            )
        case .member(let match):
            guard let lineNumber = match.member.lineNumber else { return nil }
            return ContentHighlightRequest(
                lineNumber: lineNumber,
                lineText: match.member.declarationText,
                // The part of the name the row sets apart, so the pane flashes the same span.
                matchRangeInLine: FindResultNode.nameRange(of: match).map { RuntimeTextRange(location: $0.location, length: $0.length) },
                query: match.member.name,
                matchMode: .matchingWord,
                isCaseSensitive: true
            )
        case .object, .relationship:
            return nil
        }
    }

    // MARK: - Filtering

    /// The bottom filter bar: a type row stays when its own text or any of
    /// its descendants matches, with only the matching descendants kept.
    static func filtered(_ nodes: [FindResultNode], by filterString: String) -> [FindResultNode] {
        let needle = filterString.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nodes }
        return nodes.compactMap { filtered($0, by: needle) }
    }

    /// Rows the filter does not change are returned as they are — the same instances, which the
    /// outline's diff takes as unchanged at a glance — and a row it keeps in part is copied with
    /// the appearance it already has. A keystroke builds nothing it does not have to.
    private static func filtered(_ node: FindResultNode, by needle: String) -> FindResultNode? {
        let matchesItself = node.filterableText.range(of: needle, options: [.caseInsensitive]) != nil
        if matchesItself, node.children.isEmpty {
            return node
        }
        let children = node.children.compactMap { filtered($0, by: needle) }
        if matchesItself, children.isEmpty {
            return node
        }
        guard !children.isEmpty else { return nil }
        if children.count == node.children.count, zip(children, node.children).allSatisfy({ child, original in child === original }) {
            return node
        }
        return FindResultNode(copying: node, children: children)
    }
}
