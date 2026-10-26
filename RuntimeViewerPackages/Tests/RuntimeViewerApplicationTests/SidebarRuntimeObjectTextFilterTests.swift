import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The runtime-object list under the sidebar's text filter (`NavigatorTextFilter`): every term tests one object's own
/// name — as Xcode's navigators test each item — and an object stays when it or a descendant passes the scope and every
/// term, so a type stays for a nested type the filter names.
@Suite("SidebarRuntimeObjectTextFilter", .serialized)
@MainActor
struct SidebarRuntimeObjectTextFilterTests {
    private typealias Term = NavigatorTextFilter.Term

    /// Three classes with a nested class each or none, a struct, and a struct whose only nested type is a class.
    private static let fixtureRuntimeObjects: [RuntimeObject] = [
        Fixtures.runtimeObject(name: "NSView", children: [Fixtures.runtimeObject(name: "NSViewLayer")]),
        Fixtures.runtimeObject(name: "NSViewController"),
        Fixtures.runtimeObject(name: "NSWindow", children: [Fixtures.runtimeObject(name: "NSWindowTabViewItem")]),
        Fixtures.runtimeObject(name: "ViewModelStruct", kind: .swift(.type(.struct))),
        Fixtures.runtimeObject(name: "ShapeStruct", kind: .swift(.type(.struct)), children: [Fixtures.runtimeObject(name: "CircleLayer")]),
        Fixtures.runtimeObject(name: "Unrelated"),
    ]

    /// The tree a filter pass leaves, as indented names, built the way `SidebarRuntimeObjectViewModel.scheduleRefilter()`
    /// builds its pass: without a Filter Mode the typed text joins the terms; with one it stays a fuzzy query and only the
    /// tokens' terms test names.
    private func filteredTree(
        _ filter: NavigatorTextFilter,
        filterMode: FilterMode? = nil,
        isCaseSensitive: Bool = false,
        scope: RuntimeObjectScope = .init()
    ) throws -> [String] {
        let cells = Self.fixtureRuntimeObjects.map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false) }
        let context = FilterContext(query: filterMode == nil ? "" : filter.typedText, isCaseInsensitive: !isCaseSensitive, mode: filterMode)
        let nameMatcher = NavigatorTextFilter.Matcher(terms: filterMode == nil ? filter.allTerms : filter.terms, isCaseSensitive: isCaseSensitive)
        let snapshotForest = SidebarRuntimeObjectFilterPipeline.snapshot(of: cells, scope: scope, includesHaystacks: !context.query.isEmpty)
        let forestVerdict = SidebarRuntimeObjectFilterPipeline.verdicts(for: snapshotForest, context: context, nameMatcher: nameMatcher)
        let filteredCells = try #require(
            SidebarRuntimeObjectFilterPipeline.apply(forestVerdict, to: cells, context: context, scope: scope, nameMatcher: nameMatcher)
        )
        return lines(of: filteredCells, depth: 0)
    }

    private func lines(of cells: [SidebarRuntimeObjectCellViewModel], depth: Int) -> [String] {
        cells.flatMap { cell in
            [String(repeating: "  ", count: depth) + cell.runtimeObject.displayName] + lines(of: cell.children, depth: depth + 1)
        }
    }

    // MARK: - Pipeline

    @Test("every term tests each object's own name, and a type stays for a nested type that passes")
    func termsTestEachObjectsOwnName() throws {
        #expect(try filteredTree(NavigatorTextFilter(typedText: "View !Controller")) == [
            "NSView",
            "  NSViewLayer",
            "NSWindow",
            "  NSWindowTabViewItem",
            "ViewModelStruct",
        ])
    }

    @Test("Begins With and Ends With anchor the name")
    func prefixAndSuffixAnchorTheName() throws {
        #expect(try filteredTree(NavigatorTextFilter(typedText: "*Item")) == ["NSWindow", "  NSWindowTabViewItem"])
        #expect(try filteredTree(NavigatorTextFilter(typedText: "NS*Controller")) == ["NSViewController"])
        // A type that passes keeps only the nested types that pass too, as the plain text query always did.
        #expect(try filteredTree(NavigatorTextFilter(terms: [Term(comparison: .beginsWith, value: "Shape")])) == ["ShapeStruct"])
    }

    @Test("the tokens and the typed text all have to hold")
    func tokensAndTypedTextCombine() throws {
        let filter = NavigatorTextFilter(terms: [Term(comparison: .beginsWith, value: "NS")], typedText: "!Window")
        #expect(try filteredTree(filter) == ["NSView", "  NSViewLayer", "NSViewController"])
    }

    @Test("the scope and every term have to meet in one object")
    func scopeAndTermsMeetInOneObject() throws {
        let structsOnly = RuntimeObjectScope(includedKinds: [.swift(.type(.struct))])
        #expect(try filteredTree(NavigatorTextFilter(typedText: "View"), scope: structsOnly) == ["ViewModelStruct"])
        // ShapeStruct passes the scope and CircleLayer the term, but no one object passes both.
        #expect(try filteredTree(NavigatorTextFilter(typedText: "Layer"), scope: structsOnly).isEmpty)
    }

    @Test("Match Case makes the terms tell upper from lower case")
    func matchCaseAppliesToTheTerms() throws {
        #expect(try filteredTree(NavigatorTextFilter(typedText: "view"), isCaseSensitive: true).isEmpty)
        #expect(try filteredTree(NavigatorTextFilter(typedText: "View"), isCaseSensitive: true).contains("NSView"))
    }

    @Test("with a Filter Mode the typed text stays a fuzzy query, and the tokens still test names")
    func filterModeKeepsTheTypedTextFuzzy() throws {
        let filter = NavigatorTextFilter(terms: [Term(comparison: .doesNotContain, value: "Controller")], typedText: "NSView")
        let tree = try filteredTree(filter, filterMode: .fuzzySearch)
        #expect(tree.contains("NSView"))
        #expect(!tree.contains("NSViewController"))
        #expect(!tree.contains("Unrelated"))
    }

    // MARK: - View model

    /// The view model subscribes to the shared local engine's data-change channel; its one-shot startup broadcast would
    /// otherwise land inside whichever test is running (see SharedLocalEngineTestLock.swift).
    init() async {
        await ensureSharedLocalEngineSettled()
    }

    @Test("the view model filters by the tokens and the typed text it is given")
    func viewModelFiltersByTokensAndTypedText() async throws {
        try await withSharedLocalEngineLock {
            let viewModel = TextFilterFixtureSidebarViewModel(
                seededRuntimeObjects: Self.fixtureRuntimeObjects,
                imageNode: try await makeLoadedImageNode(),
                documentState: DocumentState(),
                router: MockRouter<SidebarRuntimeObjectRoute>()
            )
            defer { withExtendedLifetime(viewModel) {} }
            let loaded = try await pollUntil(timeout: .seconds(30)) { viewModel.loadState == .loaded }
            #expect(loaded, "seeded reload never reached .loaded; state=\(viewModel.loadState)")

            let filterRelay = PublishRelay<NavigatorTextFilter>()
            _ = viewModel.transform(.init(
                runtimeObjectClicked: .never(),
                runtimeObjectOpenedInNewTab: .never(),
                loadImageClicked: .never(),
                filter: filterRelay.asDriver(onErrorJustReturn: .empty),
                isSearchCaseSensitive: .just(false)
            ))

            let filter = NavigatorTextFilter(terms: [Term(comparison: .beginsWith, value: "NS")], typedText: "!Window")
            filterRelay.accept(filter)
            let filtered = try await pollUntil(timeout: .seconds(10)) {
                viewModel.filteredNodes.map(\.runtimeObject.displayName) == ["NSView", "NSViewController"]
            }
            #expect(filtered, "got \(viewModel.filteredNodes.map(\.runtimeObject.displayName))")
            #expect(viewModel.filter == filter)
            #expect(viewModel.isFiltering)

            filterRelay.accept(.empty)
            let cleared = try await pollUntil(timeout: .seconds(10)) {
                viewModel.filteredNodes.count == Self.fixtureRuntimeObjects.count
            }
            #expect(cleared)
            #expect(!viewModel.isFiltering)
        }
    }
}

/// Serves a fixed object list so the filter, not the engine's view of the host process, decides what the suite sees.
private final class TextFilterFixtureSidebarViewModel: SidebarRuntimeObjectViewModel {
    private let seededRuntimeObjects: [RuntimeObject]

    init(
        seededRuntimeObjects: [RuntimeObject],
        imageNode: RuntimeImageNode,
        documentState: DocumentState,
        router: any Router<SidebarRuntimeObjectRoute>
    ) {
        self.seededRuntimeObjects = seededRuntimeObjects
        super.init(imageNode: imageNode, documentState: documentState, router: router)
    }

    override func buildRuntimeObjects() async throws -> [RuntimeObject] {
        seededRuntimeObjects
    }
}
