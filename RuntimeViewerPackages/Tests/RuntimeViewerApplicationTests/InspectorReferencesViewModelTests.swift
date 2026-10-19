import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import Testing
@testable import RuntimeViewerApplication

/// The Inspector's References tab, on the shared test engine with every query held to Foundation:
/// which sections apply, what they load as the insertion point moves, and what Show in Find
/// Navigator hands the Find navigator.
@Suite("InspectorReferencesViewModel", .serialized)
@MainActor
struct InspectorReferencesViewModelTests {
    private let router = MockRouter<InspectorRuntimeObjectRoute>()
    private let rowClickedRelay = PublishRelay<InspectorReferenceCellViewModel>()
    private let showInFindNavigatorClickedRelay = PublishRelay<InspectorReferencesViewModel.Section>()
    private let isVisibleRelay = BehaviorRelay<Bool>(value: true)

    private func makeViewModel(for object: RuntimeObject, in environment: ViewModelTestEnvironment) -> (InspectorReferencesViewModel, InspectorReferencesViewModel.Output) {
        let viewModel = environment.make {
            InspectorReferencesViewModel(runtimeObject: object, documentState: environment.documentState, router: router)
        }
        let output = viewModel.transform(.init(
            rowClicked: rowClickedRelay.asSignal(),
            showInFindNavigatorClicked: showInFindNavigatorClickedRelay.asSignal(),
            isVisible: isVisibleRelay.asDriver()
        ))
        return (viewModel, output)
    }

    private static func loadedRows(_ state: InspectorReferencesViewModel.SectionState) -> [InspectorReferenceCellViewModel]? {
        if case .loaded(let rows, _, _) = state { return rows }
        return nil
    }

    private static func isUnavailable(_ state: InspectorReferencesViewModel.SectionState) -> Bool {
        if case .unavailable = state { return true }
        return false
    }

    @Test("off every member's line: the type's references alone, titled by the type")
    func typeReferencesWithoutAMember() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let mutableString = try await engine.runtimeObject(named: "NSMutableString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: mutableString, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let rows = try #require(Self.loadedRows(try await nextValue(from: output.typeReferences, timeout: 60) { Self.loadedRows($0) != nil }))
        #expect(!rows.isEmpty)
        #expect(Self.isUnavailable(try await nextValue(from: output.callers)))
        #expect(Self.isUnavailable(try await nextValue(from: output.callees)))
        #expect(try await nextValue(from: output.subjectTitle) == "NSMutableString")
    }

    @Test("the member at the insertion point loads its callers and callees; another object's member does not count")
    func callsFollowTheInsertionPoint() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let mutableString = try await engine.runtimeObject(named: "NSMutableString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: mutableString, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let member = RuntimeMemberReference(object: mutableString, name: "appendString:", kind: .objcMethod, isStatic: false)

        environment.documentState.updateCursorMember(member)

        #expect(try await nextValue(from: output.subjectTitle) { $0 != "NSMutableString" } == "-[NSMutableString appendString:]")
        let callers = try #require(Self.loadedRows(try await nextValue(from: output.callers, timeout: 60) { Self.loadedRows($0) != nil }))
        #expect(!callers.isEmpty)
        #expect(callers.allSatisfy { if case .function = $0.row.item { true } else { false } })
        let callees = try #require(Self.loadedRows(try await nextValue(from: output.callees, timeout: 60) { Self.loadedRows($0) != nil }))
        #expect(callees.allSatisfy { !$0.row.isRuntimeHelperCall })

        let otherMember = RuntimeMemberReference(object: Fixtures.runtimeObject(name: "Elsewhere", kind: .objc(.type(.class))), name: "appendString:", kind: .objcMethod, isStatic: false)
        environment.documentState.updateCursorMember(otherMember)
        #expect(Self.isUnavailable(try await nextValue(from: output.callers) { Self.isUnavailable($0) }))
        #expect(try await nextValue(from: output.subjectTitle) == "NSMutableString")
    }

    @Test("Show in Find Navigator runs the section's query there, rooted at the member or the type")
    func showInFindNavigator() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let mutableString = try await engine.runtimeObject(named: "NSMutableString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, _) = makeViewModel(for: mutableString, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let session = environment.make { environment.documentState.findSession }
        var showRequestCount = 0
        let subscription = session.showResultsRequested.emitOnNext { showRequestCount += 1 }
        defer { subscription.dispose() }
        let member = RuntimeMemberReference(object: mutableString, name: "appendString:", kind: .objcMethod, isStatic: false)

        showInFindNavigatorClickedRelay.accept(.typeReferences)
        #expect(session.query.mode == .typeReferences)
        #expect(session.query.crossReferenceRoot == .type(mutableString))

        // Without a member, the calls have nothing to run.
        showInFindNavigatorClickedRelay.accept(.callers)
        #expect(session.query.mode == .typeReferences)

        environment.documentState.updateCursorMember(member)
        _ = try await nextValue(from: viewModel.$member.asObservable()) { $0 == member }
        showInFindNavigatorClickedRelay.accept(.callers)
        #expect(session.query.mode == .callHierarchy)
        #expect(session.query.crossReferenceRoot == .member(member, declaration: nil))
        #expect(showRequestCount == 2)
    }

    @Test("nothing is asked while the tab is hidden; showing it asks for what changed meanwhile, in the object's image")
    func queriesWaitForTheTabToShow() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let mutableString = try await engine.runtimeObject(named: "NSMutableString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        isVisibleRelay.accept(false)
        let (viewModel, output) = makeViewModel(for: mutableString, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        // Hidden: the type's references are not asked for.
        try await settleMainQueue()
        #expect(Self.isUnavailable(try await nextValue(from: output.typeReferences)))
        let member = RuntimeMemberReference(object: mutableString, name: "appendString:", kind: .objcMethod, isStatic: false)
        environment.documentState.updateCursorMember(member)
        try await settleMainQueue()
        #expect(Self.isUnavailable(try await nextValue(from: output.callers)))

        // Shown: both, for the member chosen while hidden, read in Foundation alone.
        isVisibleRelay.accept(true)
        let typeReferences = try #require(Self.loadedRows(try await nextValue(from: output.typeReferences, timeout: 60) { Self.loadedRows($0) != nil }))
        #expect(typeReferences.allSatisfy { $0.row.subtitle.hasPrefix("Foundation") })
        let callers = try #require(Self.loadedRows(try await nextValue(from: output.callers, timeout: 60) { Self.loadedRows($0) != nil }))
        #expect(callers.allSatisfy { $0.row.subtitle.hasPrefix("Foundation") })
        #expect(try await nextValue(from: output.scopeTitle) == "In Foundation")
    }

    @Test("a protocol has no type references section")
    func protocolsHaveNoTypeReferences() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(for: Fixtures.runtimeObject(name: "Protocolish", kind: .objc(.type(.protocol))), in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        #expect(Self.isUnavailable(try await nextValue(from: output.typeReferences)))
    }
}

/// How a loaded section of the References tab lists the functions nothing names: below one last
/// row, collapsed until a click expands it for the section's subject. Built from rows the engine
/// could have sent: the shared test engine's Foundation names every function it holds.
@Suite("InspectorReferencesViewModel unnamed functions")
@MainActor
struct InspectorReferencesUnnamedFunctionsTests {
    private static let image = "/System/Library/Frameworks/Sample.framework/Versions/A/Sample"
    private static let thing = RuntimeObject(name: "SampleThing", displayName: "SampleThing", kind: .objc(.type(.class)), imagePath: image, children: [])
    private static let request = FindCrossReferenceTree.LoadRequest.typeReferences(thing)

    /// `alpha` and two functions nothing names, each using the type once.
    private static func loadedRows() -> [FindCrossReferenceTree.LoadedRow] {
        let type = RuntimeCrossReferenceTarget.type(name: "SampleThing", object: nil)
        let functions: [(name: String?, address: UInt64)] = [("alpha", 0x2000), (nil, 0x3000), (nil, 0x4000)]
        let references = functions.map { name, address in
            let function = RuntimeFunctionReference(imagePath: image, address: address, displayName: name, symbolName: name, member: nil, foldedSymbolCount: 0)
            return RuntimeCrossReference(referencingFunction: function, instructionAddress: address + 4, kind: .typeReference, target: type, precision: .exact, isRuntimeHelperCall: false)
        }
        // One image, as the tab asks for: its functions, those nothing names gathered last.
        return FindCrossReferenceTree.rows(for: references, direction: .typeReferences).flatMap(\.children)
    }

    /// The section as listed, or `nil` when it is not loaded.
    private static func listing(showsUnnamedFunctions: Bool) -> (rows: [InspectorReferenceCellViewModel], listedCount: Int, totalCount: Int)? {
        let state = InspectorReferencesViewModel.sectionState(listing: loadedRows(), in: .typeReferences, for: request, showsUnnamedFunctions: showsUnnamedFunctions)
        guard case .loaded(let rows, let listedCount, let totalCount) = state else { return nil }
        return (rows, listedCount, totalCount)
    }

    @Test("collapsed, the functions nothing names are one last row that counts them")
    func collapsedListsOneRow() throws {
        let listing = try #require(Self.listing(showsUnnamedFunctions: false))

        #expect(listing.rows.map(\.row.title) == ["alpha", "Unnamed Functions"])
        #expect(listing.listedCount == 3)
        #expect(listing.totalCount == 3)
        let gatheringRow = try #require(listing.rows.last)
        #expect(gatheringRow.unnamedFunctionsGroup == .init(section: .typeReferences, request: Self.request, isExpanded: false))
        #expect(gatheringRow.appearance.icon === FindResultCellStyle.disclosureIcon(isExpanded: false))
        #expect(listing.rows.first?.unnamedFunctionsGroup == nil, "a function's row goes where a function goes")
    }

    @Test("expanded, the functions follow their row, and the row points down")
    func expandedListsTheFunctions() throws {
        let listing = try #require(Self.listing(showsUnnamedFunctions: true))

        #expect(listing.rows.map(\.row.title) == ["alpha", "Unnamed Functions", "Unnamed function 0x3000", "Unnamed function 0x4000"])
        #expect(listing.listedCount == 3)
        let gatheringRow = listing.rows[1]
        #expect(gatheringRow.unnamedFunctionsGroup?.isExpanded == true)
        #expect(gatheringRow.appearance.icon === FindResultCellStyle.disclosureIcon(isExpanded: true))
        #expect(Set(listing.rows.map(\.identifier)).count == listing.rows.count, "every row has an identifier of its own")
    }
}
