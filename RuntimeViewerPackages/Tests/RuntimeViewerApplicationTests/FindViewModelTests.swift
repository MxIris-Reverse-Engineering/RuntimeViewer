import AppKit
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
    private let modePathChoiceSelectedRelay = PublishRelay<FindModePathChoice>()
    private let memberKindFilterSelectedRelay = PublishRelay<FindMemberKindFilter>()
    private let caseSensitiveToggledRelay = PublishRelay<Bool>()
    private let scopeButtonClickedRelay = PublishRelay<NSView>()
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

        modePathChoiceSelectedRelay.accept(.mode(.members))
        #expect(try await nextValue(from: output.query) { $0.mode == .members }.mode == .members)
        #expect(try await nextValue(from: output.searchFieldPlaceholder) { $0 == "Member Name" } == "Member Name")

        memberKindFilterSelectedRelay.accept(.kind(.swiftFunction))
        #expect(try await nextValue(from: output.query) { $0.memberKindFilter == .kind(.swiftFunction) }.memberKindFilter == .kind(.swiftFunction))

        modePathChoiceSelectedRelay.accept(.mode(.text))
        modePathChoiceSelectedRelay.accept(.textMatchStyle(.matchingWord))
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

    // MARK: - Mode path

    @Test("the mode path is Find, the mode and its match style, the defaults unaccented")
    func modePathForDefaultQuery() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let path = try await nextValue(from: output.modePath)

        #expect(path.map(\.title) == ["Find", "Text", "Containing"])
        #expect(path.map(\.isAccented) == [false, false, false])
        #expect(path[0].menuChoices.isEmpty)
        #expect(path[1].choice == .mode(.text))
        #expect(path[1].menuChoices.map(\.title) == ["Text", "Regular Expression", "Ancestor Types", "Descendent Types", "Conforming Types", "Members"])
        #expect(path[2].choice == .textMatchStyle(.containing))
        #expect(path[2].menuChoices.map(\.title) == ["Containing", "Matching Word", "Starting With", "Ending With"])
    }

    @Test("a mode without match styles ends the path, and a choice other than the default is accented")
    func modePathAccentsChoicesOtherThanTheDefault() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        modePathChoiceSelectedRelay.accept(.mode(.regularExpression))
        let regularExpressionPath = try await nextValue(from: output.modePath) { $0.count == 2 }
        #expect(regularExpressionPath.map(\.title) == ["Find", "Regular Expression"])
        #expect(regularExpressionPath.map(\.isAccented) == [false, true])

        modePathChoiceSelectedRelay.accept(.mode(.text))
        modePathChoiceSelectedRelay.accept(.textMatchStyle(.startingWith))
        let textPath = try await nextValue(from: output.modePath) { $0.last?.choice == .textMatchStyle(.startingWith) }
        #expect(textPath.map(\.title) == ["Find", "Text", "Starting With"])
        #expect(textPath.map(\.isAccented) == [false, false, true])
    }

    @Test("Members mode offers the member match styles, the regular expression set apart")
    func modePathForMembers() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        modePathChoiceSelectedRelay.accept(.mode(.members))
        let path = try await nextValue(from: output.modePath) { $0.count == 3 && $0[1].choice == .mode(.members) }

        #expect(path.map(\.title) == ["Find", "Members", "Containing"])
        #expect(path.map(\.isAccented) == [false, true, false])
        #expect(path[2].menuChoices.map(\.title) == ["Containing", "Matching Word", "Starting With", "Ending With", "Regular Expression"])
        #expect(path[2].menuChoices.map(\.isPrecededBySeparator) == [false, false, false, false, true])
    }

    @Test("the relationship modes offer Text's match styles and keep the one chosen there")
    func modePathForRelationshipModes() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        modePathChoiceSelectedRelay.accept(.textMatchStyle(.matchingWord))
        modePathChoiceSelectedRelay.accept(.mode(.ancestorTypes))
        let path = try await nextValue(from: output.modePath) { $0.count == 3 && $0[1].choice == .mode(.ancestorTypes) }

        #expect(path.map(\.title) == ["Find", "Ancestor Types", "Matching Word"])
        #expect(path.map(\.isAccented) == [false, true, true])
        #expect(path[2].menuChoices.map(\.title) == ["Containing", "Matching Word", "Starting With", "Ending With"])

        for mode in [FindMode.descendantTypes, .conformingTypes] {
            modePathChoiceSelectedRelay.accept(.mode(mode))
            let modePath = try await nextValue(from: output.modePath) { $0.count == 3 && $0[1].choice == .mode(mode) }
            #expect(modePath[2].choice == .textMatchStyle(.matchingWord))
        }
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

        modePathChoiceSelectedRelay.accept(.mode(.members))
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

        modePathChoiceSelectedRelay.accept(.mode(.ancestorTypes))
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

    @Test("a relationship search starts from the types its match style finds")
    func relationshipSearchMatchStyle() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, _) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let session = environment.documentState.findSession

        modePathChoiceSelectedRelay.accept(.mode(.descendantTypes))
        modePathChoiceSelectedRelay.accept(.textMatchStyle(.matchingWord))
        searchCommittedRelay.accept("NSString")
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }

        // The whole name only: NSString's tree, and not NSMutableString's.
        let rootNames = session.results.nodes.compactMap { node -> String? in
            if case .object(let object, _) = node.content { return object.displayName }
            return nil
        }
        #expect(rootNames.contains("NSString"))
        #expect(rootNames.allSatisfy { $0 == "NSString" }, "\(rootNames)")
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

    // MARK: - Member match styles

    @Test("the member match style is an edit of its own, kept apart from the text match style")
    func memberMatchStyleEdit() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        modePathChoiceSelectedRelay.accept(.mode(.members))
        modePathChoiceSelectedRelay.accept(.memberMatchStyle(.regularExpression))
        let query = try await nextValue(from: output.query) { $0.memberMatchStyle == .regularExpression }

        #expect(query.textMatchStyle == .containing)
        #expect(environment.documentState.findSession.isSearching == false)
    }

    @Test("a member search matches names with the chosen match style")
    func memberSearchMatchStyle() async throws {
        let environment = try await Self.makeEnvironmentWithCorpus()
        let (viewModel, _) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let session = environment.documentState.findSession

        modePathChoiceSelectedRelay.accept(.mode(.members))
        memberKindFilterSelectedRelay.accept(.kind(.objcProperty))
        modePathChoiceSelectedRelay.accept(.memberMatchStyle(.matchingWord))
        searchCommittedRelay.accept("length")
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }

        // Whole words only: `length`, never `expectedContentLength`.
        let names = Self.memberNames(in: session.results.nodes)
        #expect(names.contains("length"))
        #expect(names.allSatisfy { $0.caseInsensitiveCompare("length") == .orderedSame }, "\(Set(names).sorted())")
    }

    // MARK: - Scope

    @Test("the scope button asks the sidebar level for the scope chooser, anchored at the button")
    func scopeButtonOpensChooser() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, _) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let scopeButton = NSView()

        scopeButtonClickedRelay.accept(scopeButton)
        try await settleMainQueue()

        #expect(router.triggeredRoutes.contains { route in
            if case .findScopeChooser(let sender) = route { return sender === scopeButton }
            return false
        })
    }

    @Test("the scope button names the scope, and its tool tip the images in it")
    func scopeButtonNamesTheScope() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let session = environment.documentState.findSession

        #expect(try await nextValue(from: output.scopeTitle) == "In Indexed Images")
        #expect(try await nextValue(from: output.scopeToolTip) == nil)

        session.update { $0.scope = .images([TestImages.foundation]) }
        #expect(try await nextValue(from: output.scopeTitle) { $0 != "In Indexed Images" } == "In Foundation")

        session.update { $0.scope = .images([TestImages.libobjc, TestImages.foundation]) }
        #expect(try await nextValue(from: output.scopeTitle) { $0 == "In 2 Images" } == "In 2 Images")
        #expect(try await nextValue(from: output.scopeToolTip) { $0?.contains("\n") == true } == "Foundation\nlibobjc.A.dylib")

        session.update { $0.scope = .currentImage }
        #expect(try await nextValue(from: output.scopeTitle) { $0 == "In Current Image" } == "In Current Image")
        #expect(try await nextValue(from: output.scopeToolTip) { $0?.contains("\n") == false } == "No image is open in the sidebar")
    }

    @Test("a search limited to picked images finds only their types")
    func searchInPickedImages() async throws {
        let environment = try await Self.makeEnvironmentWithCorpus()
        _ = try await environment.documentState.runtimeEngine.buildInterfaceCorpus(for: TestImages.libobjc, transformer: .default)
        let (viewModel, _) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let session = environment.documentState.findSession

        session.update { $0.scope = .images([TestImages.libobjc]) }
        caseSensitiveToggledRelay.accept(true)
        searchCommittedRelay.accept("NSObject")
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }

        #expect(Set(session.results.nodes.compactMap(Self.imagePath(of:))) == [TestImages.libobjc])
    }

    @Test("the current image scope searches the image the sidebar lists, and says so when it lists none")
    func currentImageScope() async throws {
        let environment = try await Self.makeEnvironmentWithCorpus()
        _ = try await environment.documentState.runtimeEngine.buildInterfaceCorpus(for: TestImages.libobjc, transformer: .default)
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let documentState = environment.documentState
        let session = documentState.findSession

        session.update { $0.scope = .currentImage }
        caseSensitiveToggledRelay.accept(true)
        searchCommittedRelay.accept("NSObject")
        #expect(try await nextValue(from: output.summary) { $0 != nil } == "No current image")

        // The tree has to outlive the search: a node reaches its path through
        // its parent, which it holds weakly.
        let imageTree = Fixtures.imageTree(rootName: "Images", imagePaths: [TestImages.libobjc])
        documentState.selectionRouter.trigger(.switchImage(try #require(imageTree.leaf(forImagePath: TestImages.libobjc))))
        searchCommittedRelay.accept("NSObject")
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }

        #expect(Set(session.results.nodes.compactMap(Self.imagePath(of:))) == [TestImages.libobjc])
        withExtendedLifetime(imageTree) {}
    }

    @Test("a relationship search limited to picked images lists their types and the paths to them")
    func relationshipSearchInPickedImages() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        environment.documentState.findSession.update { $0.scope = .images([TestImages.foundation]) }
        modePathChoiceSelectedRelay.accept(.mode(.descendantTypes))
        caseSensitiveToggledRelay.accept(true)
        searchCommittedRelay.accept("NSObject")
        let nodes = try await nextValue(from: output.nodes, timeout: 60) { !$0.isEmpty }

        // NSObject itself is libobjc's; what is listed under it is Foundation's.
        let tree = try #require(nodes.first { node in
            if case .object(let object, _) = node.content { return object.name == "NSObject" && object.kind == .objc(.type(.class)) }
            return false
        })
        func everyNode(of nodes: [FindResultNode]) -> [FindResultNode] {
            nodes.flatMap { [$0] + everyNode(of: $0.children) }
        }
        let relatedObjects = everyNode(of: tree.children).compactMap { node -> RuntimeObject? in
            if case .relationship(_, let object) = node.content { return object }
            return nil
        }
        #expect(relatedObjects.contains { $0.name == "NSString" })
        #expect(!relatedObjects.contains { $0.name == "Protocol" && $0.imagePath == TestImages.libobjc })
    }

    // MARK: - Helpers

    private static func imagePath(of node: FindResultNode) -> String? {
        if case .object(let object, _) = node.content {
            return object.imagePath
        }
        return nil
    }

    private static func memberNames(in nodes: [FindResultNode]) -> [String] {
        nodes.flatMap(\.children).compactMap { node in
            if case .member(let match) = node.content { return match.member.name }
            return nil
        }
    }

    private func makeViewModel(in environment: ViewModelTestEnvironment) -> (FindViewModel<SidebarRootRoute>, FindViewModel<SidebarRootRoute>.Output) {
        let viewModel = environment.make {
            FindViewModel<SidebarRootRoute>(documentState: environment.documentState, router: router)
        }
        let output = viewModel.transform(.init(
            modePathChoiceSelected: modePathChoiceSelectedRelay.asSignal(),
            memberKindFilterSelected: memberKindFilterSelectedRelay.asSignal(),
            caseSensitiveToggled: caseSensitiveToggledRelay.asSignal(),
            scopeButtonClicked: scopeButtonClickedRelay.asSignal(),
            searchCommitted: searchCommittedRelay.asSignal(),
            filterString: filterStringRelay.asDriver(),
            resultClicked: resultClickedRelay.asSignal(),
            resultOpenedInNewTab: resultOpenedInNewTabRelay.asSignal()
        ))
        return (viewModel, output)
    }
}
