import RuntimeViewerArchitectures
@testable import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("InspectorClassViewModel")
@MainActor
struct InspectorClassViewModelTests {
    private let router = MockRouter<InspectorRuntimeObjectRoute>()
    private let selectHierarchyLevelRelay = PublishRelay<InspectorClassHierarchyCellViewModel>()

    @Test("lists the inspected class, then its superclasses nearest first, each as the object it is")
    func listsTheClassThenItsSuperclasses() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let mutableString = try await engine.runtimeObject(named: "NSMutableString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let string = try await engine.runtimeObject(named: "NSString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let object = try await engine.runtimeObject(named: "NSObject", kind: .objc(.type(.class)), in: TestImages.libobjc)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: mutableString, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let rows = try await loadedRows(from: output.hierarchyState)

        #expect(rows.map(\.runtimeObject) == [mutableString, string, object], "\(rows.map(\.name))")
    }

    @Test("update(for:) replaces the hierarchy with the new object's")
    func updateReplacesHierarchy() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let mutableString = try await engine.runtimeObject(named: "NSMutableString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let object = try await engine.runtimeObject(named: "NSObject", kind: .objc(.type(.class)), in: TestImages.libobjc)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: mutableString, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        _ = try await loadedRows(from: output.hierarchyState)

        viewModel.update(for: object)

        let rows = try await loadedRows(from: output.hierarchyState) { $0.first?.runtimeObject == object }
        #expect(rows.map(\.runtimeObject) == [object])
    }

    @Test("update(for:) with the object already shown does not refetch")
    func updateWithSameObjectDoesNotRefetch() async throws {
        let environment = ViewModelTestEnvironment()
        let sample = Fixtures.runtimeObject(kind: .objc(.type(.class)))
        let (viewModel, output) = makeViewModel(for: sample, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        _ = try await loadedRows(from: output.hierarchyState)

        async let emissions = values(from: output.hierarchyState.skip(1), during: 0.5)
        try await settleMainQueue()
        viewModel.update(for: sample)

        #expect(try await emissions.isEmpty)
    }

    @Test("an object from an image the engine has not indexed lists itself alone rather than failing")
    func unknownImageListsTheObjectAlone() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let sample = Fixtures.runtimeObject(kind: .objc(.type(.class)))
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: sample, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let rows = try await loadedRows(from: output.hierarchyState)

        #expect(rows.map(\.runtimeObject) == [sample])
    }

    @Test("a superclass no indexed image defines is a level known by its name alone")
    func unresolvedSuperclassIsListedByName() {
        let level = InspectorClassHierarchyCellViewModel(level: RuntimeRelationshipNode(name: "NSObject", object: nil, children: []))

        #expect(level.runtimeObject == nil)
        #expect(level.name == "NSObject")
        #expect(level.appearance.title.string == "NSObject")
        #expect(level.appearance.subtitle == nil)
    }

    #if canImport(Network)
    @Test("a peer older than the superclass chain lists the names it has, every superclass unresolved")
    func olderPeerListsItsNames() async throws {
        let peer = try await ScriptedPeer.make(label: "InspectorClassViewModelTests.olderPeer")
        // What a release before the superclass chain answers: the names, the
        // class itself first, and no handler for the chain.
        peer.serve(.runtimeObjectHierarchy) { () async throws -> [String] in ["NSMutableString", "NSString", "NSObject"] }
        let mutableString = Fixtures.runtimeObject(name: "NSMutableString", kind: .objc(.type(.class)), imagePath: TestImages.foundation)
        let environment = ViewModelTestEnvironment(runtimeEngine: peer.client)
        let (viewModel, output) = makeViewModel(for: mutableString, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let rows = try await loadedRows(from: output.hierarchyState)
        await peer.stop()

        #expect(rows.map(\.name) == ["NSMutableString", "NSString", "NSObject"])
        #expect(rows.map(\.runtimeObject) == [mutableString, nil, nil])
    }
    #endif

    @Test("clicking a superclass pushes it onto the document timeline")
    func clickingSuperclassPushesIt() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let mutableString = try await engine.runtimeObject(named: "NSMutableString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: mutableString, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let superclassRow = try #require(try await loadedRows(from: output.hierarchyState).dropFirst().first)

        selectHierarchyLevelRelay.accept(superclassRow)
        try await settleMainQueue()

        #expect(environment.documentState.selectedRuntimeObject == superclassRow.runtimeObject)
        #expect(router.triggeredRoutes.isEmpty)
    }

    @Test("clicking the inspected class or a level known by name only opens nothing")
    func clickingTheClassOrAnUnresolvedLevelOpensNothing() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let mutableString = try await engine.runtimeObject(named: "NSMutableString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: mutableString, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let inspectedClassRow = try #require(try await loadedRows(from: output.hierarchyState).first)

        selectHierarchyLevelRelay.accept(inspectedClassRow)
        selectHierarchyLevelRelay.accept(InspectorClassHierarchyCellViewModel(unresolvedName: "NSObject"))
        try await settleMainQueue()

        #expect(environment.documentState.selectedRuntimeObject == nil)
        #expect(router.triggeredRoutes.isEmpty)
    }

    // MARK: - Helpers

    private func makeViewModel(
        for runtimeObject: RuntimeObject,
        in environment: ViewModelTestEnvironment
    ) -> (InspectorClassViewModel, InspectorClassViewModel.Output) {
        let viewModel = environment.make {
            InspectorClassViewModel(runtimeObject: runtimeObject, documentState: environment.documentState, router: router)
        }
        let output = viewModel.transform(.init(selectHierarchyLevelClicked: selectHierarchyLevelRelay.asSignal()))
        return (viewModel, output)
    }

    private func loadedRows(
        from state: Driver<InspectorClassViewModel.HierarchyState>,
        where predicate: @escaping ([InspectorClassHierarchyCellViewModel]) -> Bool = { _ in true }
    ) async throws -> [InspectorClassHierarchyCellViewModel] {
        let loaded = try await nextValue(from: state, timeout: 60) { state in
            if case .loaded(let rows) = state { return predicate(rows) }
            return false
        }
        guard case .loaded(let rows) = loaded else { return [] }
        return rows
    }
}
