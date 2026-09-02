import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("InspectorRelationshipsViewModel")
@MainActor
struct InspectorRelationshipsViewModelTests {
    private let router = MockRouter<InspectorRuntimeObjectRoute>()
    private let selectRelationshipRelay = PublishRelay<InspectorRelationshipsCellViewModel>()

    // MARK: - Section texts (no engine involved)

    @Test(
        "the section title follows the inspected object's kind",
        arguments: [
            (RuntimeObjectKind.objc(.type(.class)), "Subclasses"),
            (.swift(.type(.class)), "Subclasses"),
            (.objc(.type(.protocol)), "Conforming Types"),
            (.swift(.type(.protocol)), "Conforming Types"),
            (.swift(.type(.struct)), ""),
            (.objc(.category(.class)), ""),
        ]
    )
    func sectionTitleFollowsKind(_ argument: (kind: RuntimeObjectKind, title: String)) async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(for: Fixtures.runtimeObject(kind: argument.kind), in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        #expect(try await nextValue(from: output.sectionTitle) == argument.title)
    }

    @Test("the empty message names the relationship being listed")
    func emptyMessageNamesRelationship() async throws {
        let environment = ViewModelTestEnvironment()
        let (classViewModel, classOutput) = makeViewModel(for: Fixtures.runtimeObject(kind: .swift(.type(.class))), in: environment)
        let (protocolViewModel, protocolOutput) = makeViewModel(for: Fixtures.runtimeObject(kind: .objc(.type(.protocol))), in: environment)
        defer { withExtendedLifetime((classViewModel, protocolViewModel)) {} }

        #expect(try await nextValue(from: classOutput.emptyMessage) == "No subclasses found in indexed images.")
        #expect(try await nextValue(from: protocolOutput.emptyMessage) == "No conforming types found in indexed images.")
    }

    @Test("an object that is neither a class nor a protocol loads an empty list")
    func unsupportedKindLoadsEmpty() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(for: Fixtures.runtimeObject(kind: .swift(.type(.struct))), in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        #expect(try await loadedRows(from: output.state).isEmpty)
    }

    // MARK: - Engine-backed

    @Test("a class lists its direct subclasses from every indexed image")
    func classListsSubclasses() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let nsObject = try await engine.runtimeObject(named: "NSObject", kind: .objc(.type(.class)), in: TestImages.libobjc)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: nsObject, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let rows = try await loadedRows(from: output.state)
        #expect(rows.map(\.runtimeObject.name).contains("NSString"))
        #expect(rows.allSatisfy { $0.runtimeObject.kind == .objc(.type(.class)) || $0.runtimeObject.kind == .swift(.type(.class)) })
    }

    @Test("clicking a relationship pushes that object onto the document timeline")
    func clickingRelationshipPushesIt() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let nsObject = try await engine.runtimeObject(named: "NSObject", kind: .objc(.type(.class)), in: TestImages.libobjc)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: nsObject, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let row = try #require(try await loadedRows(from: output.state).first)

        selectRelationshipRelay.accept(row)
        try await settleMainQueue()

        #expect(environment.documentState.selectedRuntimeObject == row.runtimeObject)
        #expect(router.triggeredRoutes.isEmpty)
    }

    @Test("update(for:) switches the section texts at once and reloads the rows")
    func updateSwitchesTextsAndReloads() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let nsObject = try await engine.runtimeObject(named: "NSObject", kind: .objc(.type(.class)), in: TestImages.libobjc)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: nsObject, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        #expect(try await loadedRows(from: output.state).isEmpty == false)

        viewModel.update(for: Fixtures.runtimeObject(name: "Sample", kind: .swift(.type(.protocol))))

        #expect(viewModel.sectionTitle == "Conforming Types")
        #expect(try await loadedRows(from: output.state) { $0.isEmpty }.isEmpty)
    }

    @Test("update(for:) with the object already shown does not reload")
    func updateWithSameObjectDoesNotReload() async throws {
        let environment = ViewModelTestEnvironment()
        let sample = Fixtures.runtimeObject(kind: .swift(.type(.struct)))
        let (viewModel, output) = makeViewModel(for: sample, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        _ = try await loadedRows(from: output.state)

        async let emissions = values(from: output.state.skip(1), during: 0.5)
        try await settleMainQueue()
        viewModel.update(for: sample)

        #expect(try await emissions.isEmpty)
    }

    // MARK: - Helpers

    private func makeViewModel(
        for runtimeObject: RuntimeObject,
        in environment: ViewModelTestEnvironment
    ) -> (InspectorRelationshipsViewModel, InspectorRelationshipsViewModel.Output) {
        let viewModel = environment.make {
            InspectorRelationshipsViewModel(runtimeObject: runtimeObject, documentState: environment.documentState, router: router)
        }
        let output = viewModel.transform(.init(selectRelationshipClicked: selectRelationshipRelay.asSignal()))
        return (viewModel, output)
    }

    private func loadedRows(
        from state: Driver<InspectorRelationshipsViewModel.RelationshipsState>,
        where predicate: @escaping ([InspectorRelationshipsCellViewModel]) -> Bool = { _ in true }
    ) async throws -> [InspectorRelationshipsCellViewModel] {
        let loaded = try await nextValue(from: state, timeout: 60) { state in
            if case .loaded(let rows) = state { return predicate(rows) }
            return false
        }
        guard case .loaded(let rows) = loaded else { return [] }
        return rows
    }
}
