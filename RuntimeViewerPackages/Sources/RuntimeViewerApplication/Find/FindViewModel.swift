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
    @MemberwiseInit(.public)
    public struct Input {
        /// A choice made in one of the mode path's menus.
        public let modePathChoiceSelected: Signal<FindModePathChoice>
        public let memberKindFilterSelected: Signal<FindMemberKindFilter>
        public let caseSensitiveToggled: Signal<Bool>
        /// A choice made in the scope button's menu.
        public let scopeMenuChoiceSelected: Signal<FindScopeMenuChoice>
        /// Return in the search field: the text to search for.
        public let searchCommitted: Signal<String>
        /// The bottom filter bar, as typed.
        public let filterString: Driver<String>
        public let resultClicked: Signal<FindResultNode>
        public let resultOpenedInNewTab: Signal<FindResultNode>
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
        public let nodes: Driver<[FindResultNode]>
        /// `nil` hides the summary bar.
        public let summary: Driver<String?>
        public let isSearching: Driver<Bool>
        public let focusSearchField: Signal<Void>
        /// Fired after a search delivers its first results, so the outline
        /// expands them; matches are only useful expanded.
        public let expandAll: Signal<Void>
    }

    private let session: FindSession

    @RxObserved
    private var filterString: String = ""

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

        input.searchCommitted.emitOnNext { [session] text in
            var query = session.query
            query.text = text
            session.run(query)
        }
        .disposed(by: rx.disposeBag)

        input.filterString.driveOnNext { [weak self] filterString in
            self?.filterString = filterString
        }
        .disposed(by: rx.disposeBag)

        input.resultClicked.emitOnNext { [weak self] node in
            self?.navigate(to: node, inNewTab: false)
        }
        .disposed(by: rx.disposeBag)

        input.resultOpenedInNewTab.emitOnNext { [weak self] node in
            self?.navigate(to: node, inNewTab: true)
        }
        .disposed(by: rx.disposeBag)

        let nodes = Driver.combineLatest(session.$results.asDriver(), $filterString.asDriver()) { results, filterString -> [FindResultNode] in
            Self.filtered(results.nodes, by: filterString)
        }

        let expandAll = session.$results.asObservable()
            .map { !$0.nodes.isEmpty }
            .distinctUntilChanged()
            .filter { $0 }
            .map { _ in () }
            .asSignal(onErrorSignalWith: .empty())

        let scope = session.$query.asDriver().map(\.scope).distinctUntilChanged()
        let currentImagePath = documentState.$currentImageNode.asDriver().map { $0?.path }
        let scopeToolTip = Driver.combineLatest(scope, currentImagePath) { scope, currentImagePath in
            Self.toolTip(for: scope, currentImagePath: currentImagePath)
        }
        let scopeMenuItems = Driver.combineLatest(scope, currentImagePath, nodes.map { !$0.isEmpty }.distinctUntilChanged()) { scope, currentImagePath, hasVisibleResults in
            FindScopeMenuItem.menu(for: scope, currentImagePath: currentImagePath, hasVisibleResults: hasVisibleResults)
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
            nodes: nodes,
            summary: session.$summary.asDriver(),
            isSearching: session.$isSearching.asDriver(),
            focusSearchField: session.focusSearchFieldRelay.asSignal(),
            expandAll: expandAll
        )
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
                if let imagePath = node.navigationTarget?.object.imagePath {
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

    private func navigate(to node: FindResultNode, inNewTab: Bool) {
        guard let (object, _) = node.navigationTarget else { return }
        let highlight = Self.highlight(for: node, query: session.query)
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
    /// pane to scroll to; type rows and relationship rows carry no place.
    private static func highlight(for node: FindResultNode, query: FindQuery) -> ContentHighlightRequest? {
        switch node.content {
        case .textMatch(let match):
            return ContentHighlightRequest(
                lineNumber: match.lineNumber,
                lineText: match.lineText,
                matchRangeInLine: match.matchRangeInLine,
                query: query.mode == .regularExpression ? "" : query.trimmedText,
                isCaseSensitive: query.isCaseSensitive
            )
        case .member(let match):
            guard let lineNumber = match.member.lineNumber else { return nil }
            return ContentHighlightRequest(
                lineNumber: lineNumber,
                lineText: match.member.declarationText,
                matchRangeInLine: nil,
                query: match.member.name,
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

    private static func filtered(_ node: FindResultNode, by needle: String) -> FindResultNode? {
        let matchesItself = node.filterableText.range(of: needle, options: [.caseInsensitive]) != nil
        let children = node.children.compactMap { filtered($0, by: needle) }
        if matchesItself, children.isEmpty, !node.children.isEmpty {
            return node
        }
        guard matchesItself || !children.isEmpty else { return nil }
        return FindResultNode(content: node.content, children: children, identifier: node.identifier)
    }
}
