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

    private func makeViewModel(for object: RuntimeObject, in environment: ViewModelTestEnvironment) -> (InspectorReferencesViewModel, InspectorReferencesViewModel.Output) {
        let viewModel = environment.make {
            InspectorReferencesViewModel(runtimeObject: object, documentState: environment.documentState, router: router, scope: .image(path: object.imagePath))
        }
        let output = viewModel.transform(.init(
            rowClicked: rowClickedRelay.asSignal(),
            showInFindNavigatorClicked: showInFindNavigatorClickedRelay.asSignal()
        ))
        return (viewModel, output)
    }

    private static func loadedRows(_ state: InspectorReferencesViewModel.SectionState) -> [InspectorReferenceCellViewModel]? {
        if case .loaded(let rows, _) = state { return rows }
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

    @Test("a protocol has no type references section")
    func protocolsHaveNoTypeReferences() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(for: Fixtures.runtimeObject(name: "Protocolish", kind: .objc(.type(.protocol))), in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        #expect(Self.isUnavailable(try await nextValue(from: output.typeReferences)))
    }
}
