import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The Find navigator page's contract: the mode path and the toggles edit the
/// query without searching, Return searches, results group hits by type,
/// clicks navigate and leave the content pane its highlight, and the bottom
/// filter narrows what is shown.
///
/// Engine-backed cases run on the shared test engine (libobjc + Foundation);
/// the Foundation corpus is built once per process by whichever case gets
/// there first, and the store hands every later request the same corpus.
@Suite("FindViewModel", .serialized)
@MainActor
struct FindViewModelTests {
    private let router = MockRouter<SidebarRootRoute>()
    private let modeSelectedRelay = PublishRelay<FindMode>()
    private let textMatchStyleSelectedRelay = PublishRelay<FindTextMatchStyle>()
    private let memberKindFilterSelectedRelay = PublishRelay<FindMemberKindFilter>()
    private let caseSensitiveToggledRelay = PublishRelay<Bool>()
    private let searchCommittedRelay = PublishRelay<String>()
    private let filterStringRelay = BehaviorRelay<String>(value: "")
    private let resultClickedRelay = PublishRelay<FindResultNode>()
    private let resultOpenedInNewTabRelay = PublishRelay<FindResultNode>()

    private static func makeEnvironmentWithCorpus() async throws -> ViewModelTestEnvironment {
        let engine = try await TestRuntimeEngine.shared()
        _ = try await engine.buildInterfaceCorpus(for: TestImages.foundation, transformer: .default)
        return ViewModelTestEnvironment(runtimeEngine: engine)
    }

    // MARK: - Query editing

    @Test("mode, match style, member kind and case edits change the query without searching")
    func editsChangeQueryWithoutSearching() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        modeSelectedRelay.accept(.members)
        #expect(try await nextValue(from: output.query) { $0.mode == .members }.mode == .members)
        #expect(try await nextValue(from: output.searchFieldPlaceholder) { $0 == "Member Name" } == "Member Name")

        memberKindFilterSelectedRelay.accept(.kind(.swiftFunction))
        #expect(try await nextValue(from: output.query) { $0.memberKindFilter == .kind(.swiftFunction) }.memberKindFilter == .kind(.swiftFunction))

        modeSelectedRelay.accept(.text)
        textMatchStyleSelectedRelay.accept(.matchingWord)
        caseSensitiveToggledRelay.accept(true)
        let query = try await nextValue(from: output.query) { $0.textMatchStyle == .matchingWord && $0.isCaseSensitive }
        #expect(query.mode == .text)

        #expect(try await nextValue(from: output.nodes).isEmpty)
        #expect(try await nextValue(from: output.summary) == nil)
        #expect(environment.documentState.findSession.isSearching == false)
    }

    @Test("committing an empty query clears the results")
    func emptyQueryClears() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        searchCommittedRelay.accept("   ")
        try await settleMainQueue()

        #expect(try await nextValue(from: output.nodes).isEmpty)
        #expect(try await nextValue(from: output.summary) == nil)
        #expect(try await nextValue(from: output.isSearching) == false)
    }

    // MARK: - Text search

    @Test("a text search groups hits by type and reports a summary")
    func textSearchGroupsHits() async throws {
        let environment = try await Self.makeEnvironmentWithCorpus()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        caseSensitiveToggledRelay.accept(true)
        searchCommittedRelay.accept("NSMutableString")
        let nodes = try await nextValue(from: output.nodes, timeout: 60) { nodes in
            nodes.contains { node in
                if case .object(let object, _) = node.content { return object.name == "NSMutableString" && object.kind == .objc(.type(.class)) }
                return false
            }
        }
        let typeNode = try #require(nodes.first { node in
            if case .object(let object, _) = node.content { return object.name == "NSMutableString" && object.kind == .objc(.type(.class)) }
            return false
        })
        #expect(!typeNode.children.isEmpty)
        for child in typeNode.children {
            guard case .textMatch(let match) = child.content else {
                Issue.record("a type's children are its hits")
                continue
            }
            #expect(match.lineNumber >= 1)
        }

        let summary = try await nextValue(from: output.summary, timeout: 60) { $0?.contains("results in") == true }
        #expect(summary?.contains("types") == true)
        #expect(try await nextValue(from: output.isSearching) { !$0 } == false)
    }

    @Test("clicking a hit pushes its type and leaves the content pane its highlight")
    func clickingHitPushesAndHighlights() async throws {
        let environment = try await Self.makeEnvironmentWithCorpus()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        searchCommittedRelay.accept("initWithFormat:")
        let nodes = try await nextValue(from: output.nodes, timeout: 60) { !$0.isEmpty }
        let hit = try #require(nodes.first?.children.first)
        guard case .textMatch(let match) = hit.content else {
            Issue.record("expected a text hit")
            return
        }

        resultClickedRelay.accept(hit)
        try await settleMainQueue()

        #expect(environment.documentState.selectedRuntimeObject == match.object)
        let highlight = try #require(environment.documentState.takeContentHighlight(for: match.object))
        #expect(highlight.lineNumber == match.lineNumber)
        #expect(highlight.lineText == match.lineText)
        #expect(highlight.matchRangeInLine == match.matchRangeInLine)
        #expect(highlight.query == "initWithFormat:")
        // Taken once: the second ask finds nothing.
        #expect(environment.documentState.takeContentHighlight(for: match.object) == nil)
        #expect(router.triggeredRoutes.isEmpty)
    }

    @Test("clicking a type row pushes it with no highlight; opening in a new tab adds a tab")
    func clickingTypeRow() async throws {
        let environment = try await Self.makeEnvironmentWithCorpus()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        searchCommittedRelay.accept("NSMutableString")
        let nodes = try await nextValue(from: output.nodes, timeout: 60) { !$0.isEmpty }
        let typeNode = try #require(nodes.first)
        guard case .object(let object, _) = typeNode.content else {
            Issue.record("expected a type row")
            return
        }

        resultClickedRelay.accept(typeNode)
        try await settleMainQueue()
        #expect(environment.documentState.selectedRuntimeObject == object)
        #expect(environment.documentState.pendingContentHighlight == nil)

        let tabCount = environment.documentState.tabs.count
        resultOpenedInNewTabRelay.accept(typeNode)
        try await settleMainQueue()
        #expect(environment.documentState.tabs.count == tabCount + 1)
    }

    @Test("the filter bar narrows the results to the rows that match it")
    func filterNarrowsResults() async throws {
        let environment = try await Self.makeEnvironmentWithCorpus()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        searchCommittedRelay.accept("NSString")
        let unfiltered = try await nextValue(from: output.nodes, timeout: 60) { !$0.isEmpty && $0.count > 1 }

        filterStringRelay.accept("NSMutableString")
        let filtered = try await nextValue(from: output.nodes) { $0.count < unfiltered.count }
        #expect(filtered.allSatisfy { $0.filterableText.localizedCaseInsensitiveContains("NSMutableString") || $0.children.contains { $0.filterableText.localizedCaseInsensitiveContains("NSMutableString") } })

        filterStringRelay.accept("")
        #expect(try await nextValue(from: output.nodes) { $0.count == unfiltered.count }.count == unfiltered.count)
    }

    // MARK: - Members

    @Test("a member search lists members of the chosen kind and highlights their declaration line")
    func memberSearch() async throws {
        let environment = try await Self.makeEnvironmentWithCorpus()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        modeSelectedRelay.accept(.members)
        memberKindFilterSelectedRelay.accept(.kind(.objcMethod))
        caseSensitiveToggledRelay.accept(true)
        searchCommittedRelay.accept("initWithFormat:")
        let nodes = try await nextValue(from: output.nodes, timeout: 60) { !$0.isEmpty }
        let member = try #require(nodes.flatMap(\.children).first { node in
            if case .member(let match) = node.content { return match.member.lineNumber != nil }
            return false
        })
        guard case .member(let match) = member.content else { return }
        #expect(match.member.kind == .objcMethod)
        #expect(match.member.name.contains("initWithFormat:"))

        resultClickedRelay.accept(member)
        try await settleMainQueue()
        let highlight = try #require(environment.documentState.takeContentHighlight(for: match.object))
        #expect(highlight.lineNumber == match.member.lineNumber)
        #expect(highlight.query == match.member.name)
    }

    // MARK: - Relationships

    @Test("a relationship search builds one tree per matching type")
    func relationshipSearch() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        modeSelectedRelay.accept(.ancestorTypes)
        caseSensitiveToggledRelay.accept(true)
        searchCommittedRelay.accept("NSMutableString")
        let nodes = try await nextValue(from: output.nodes, timeout: 60) { !$0.isEmpty }
        let tree = try #require(nodes.first { node in
            if case .object(let object, _) = node.content { return object.name == "NSMutableString" }
            return false
        })
        let superclass = try #require(tree.children.first { node in
            if case .relationship(let name, let object) = node.content { return name == "NSString" && object != nil }
            return false
        })
        #expect(!superclass.children.isEmpty)
        let summary = try await nextValue(from: output.summary, timeout: 60) { $0 != nil }
        #expect(summary?.contains("types for") == true)
    }

    @Test("an unresolved relationship node goes nowhere when clicked")
    func unresolvedNodeGoesNowhere() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, _) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let node = FindResultNode(content: .relationship(name: "Swift.Error", object: nil), identifier: "unresolved")
        resultClickedRelay.accept(node)
        try await settleMainQueue()

        #expect(environment.documentState.selectedRuntimeObject == nil)
    }

    // MARK: - Failure and focus

    @Test("a search the engine cannot serve reports the failure in the summary")
    func unreachableEngineReportsFailure() async throws {
        let environment = ViewModelTestEnvironment(runtimeEngine: TestRuntimeEngine.makeUnreachable())
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        searchCommittedRelay.accept("anything")
        let summary = try await nextValue(from: output.summary, timeout: 30) { $0?.hasPrefix("Search failed") == true }
        #expect(summary != nil)
        #expect(try await nextValue(from: output.isSearching) { !$0 } == false)
    }

    @Test("the session's focus request reaches the page")
    func focusRequestReachesPage() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        async let focused: Void = nextValue(from: output.focusSearchField)
        try await settleMainQueue()
        environment.documentState.findSession.focusSearchFieldRelay.accept(())
        try await focused
    }

    // MARK: - Helpers

    private func makeViewModel(in environment: ViewModelTestEnvironment) -> (FindViewModel<SidebarRootRoute>, FindViewModel<SidebarRootRoute>.Output) {
        let viewModel = environment.make {
            FindViewModel<SidebarRootRoute>(documentState: environment.documentState, router: router)
        }
        let output = viewModel.transform(.init(
            modeSelected: modeSelectedRelay.asSignal(),
            textMatchStyleSelected: textMatchStyleSelectedRelay.asSignal(),
            memberKindFilterSelected: memberKindFilterSelectedRelay.asSignal(),
            caseSensitiveToggled: caseSensitiveToggledRelay.asSignal(),
            searchCommitted: searchCommittedRelay.asSignal(),
            filterString: filterStringRelay.asDriver(),
            resultClicked: resultClickedRelay.asSignal(),
            resultOpenedInNewTab: resultOpenedInNewTabRelay.asSignal()
        ))
        return (viewModel, output)
    }
}
