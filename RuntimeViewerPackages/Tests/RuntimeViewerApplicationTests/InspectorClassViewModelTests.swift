import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("InspectorClassViewModel")
@MainActor
struct InspectorClassViewModelTests {
    private let router = MockRouter<InspectorRuntimeObjectRoute>()

    @Test("shows the inherited chain of an Objective-C class, one class per line")
    func showsInheritanceChain() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let nsMutableString = try await engine.runtimeObject(named: "NSMutableString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: nsMutableString, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let lines = try await loadedHierarchy(from: output.hierarchyState).components(separatedBy: "\n")
        #expect(lines.contains("NSObject"))
        #expect(lines.contains("NSString"))
        #expect(lines.contains("NSMutableString"))
    }

    @Test("update(for:) replaces the hierarchy with the new object's")
    func updateReplacesHierarchy() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let nsMutableString = try await engine.runtimeObject(named: "NSMutableString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let nsObject = try await engine.runtimeObject(named: "NSObject", kind: .objc(.type(.class)), in: TestImages.libobjc)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: nsMutableString, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        _ = try await loadedHierarchy(from: output.hierarchyState)

        viewModel.update(for: nsObject)

        let hierarchy = try await loadedHierarchy(from: output.hierarchyState) { !$0.contains("NSMutableString") }
        #expect(hierarchy.components(separatedBy: "\n").contains("NSObject"))
    }

    @Test("update(for:) with the object already shown does not refetch")
    func updateWithSameObjectDoesNotRefetch() async throws {
        let environment = ViewModelTestEnvironment()
        let sample = Fixtures.runtimeObject(kind: .objc(.type(.class)))
        let (viewModel, output) = makeViewModel(for: sample, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        _ = try await loadedHierarchy(from: output.hierarchyState)

        async let emissions = values(from: output.hierarchyState.skip(1), during: 0.5)
        try await settleMainQueue()
        viewModel.update(for: sample)

        #expect(try await emissions.isEmpty)
    }

    @Test("an object from an image the engine has not indexed yields an empty hierarchy rather than an error")
    func unknownImageYieldsEmptyHierarchy() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: Fixtures.runtimeObject(kind: .objc(.type(.class))), in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        #expect(try await loadedHierarchy(from: output.hierarchyState) == "")
    }

    // MARK: - Helpers

    private func makeViewModel(
        for runtimeObject: RuntimeObject,
        in environment: ViewModelTestEnvironment
    ) -> (InspectorClassViewModel, InspectorClassViewModel.Output) {
        let viewModel = environment.make {
            InspectorClassViewModel(runtimeObject: runtimeObject, documentState: environment.documentState, router: router)
        }
        return (viewModel, viewModel.transform(.init()))
    }

    private func loadedHierarchy(
        from state: Driver<InspectorClassViewModel.HierarchyState>,
        where predicate: @escaping (String) -> Bool = { _ in true }
    ) async throws -> String {
        let loaded = try await nextValue(from: state, timeout: 60) { state in
            if case .loaded(let hierarchy) = state { return predicate(hierarchy) }
            return false
        }
        guard case .loaded(let hierarchy) = loaded else { return "" }
        return hierarchy
    }
}
