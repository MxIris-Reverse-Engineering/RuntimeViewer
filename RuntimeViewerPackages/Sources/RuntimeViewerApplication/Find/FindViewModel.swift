import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit
import UIFoundation

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
        /// The scope button, which the scope chooser is anchored at.
        public let scopeButtonClicked: Signal<NSUIView>
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
        /// The images a scope names, or what the sidebar lists for the current
        /// image; `nil` for every indexed image.
        public let scopeToolTip: Driver<String?>
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

        input.scopeButtonClicked.emitOnNext { [weak self] sender in
            guard let self else { return }
            router.trigger(.findScopeChooser(sender: sender))
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
        let scopeToolTip = Driver.combineLatest(scope, documentState.$currentImageNode.asDriver()) { scope, currentImageNode in
            Self.toolTip(for: scope, currentImagePath: currentImageNode?.path)
        }

        return Output(
            query: session.$query.asDriver(),
            modePath: session.$query.asDriver().map(FindModePathComponent.path(for:)).distinctUntilChanged(),
            scopeTitle: scope.map(\.title),
            scopeToolTip: scopeToolTip,
            searchFieldPlaceholder: session.$query.asDriver().map(\.mode.searchFieldPlaceholder),
            nodes: nodes,
            summary: session.$summary.asDriver(),
            isSearching: session.$isSearching.asDriver(),
            focusSearchField: session.focusSearchFieldRelay.asSignal(),
            expandAll: expandAll
        )
    }

    // MARK: - Scope

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
