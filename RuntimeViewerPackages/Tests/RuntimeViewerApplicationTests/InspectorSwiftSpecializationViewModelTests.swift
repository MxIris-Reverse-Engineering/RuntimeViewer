import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("InspectorSwiftSpecializationViewModel")
@MainActor
struct InspectorSwiftSpecializationViewModelTests {
    private let environment = ViewModelTestEnvironment()
    private let router = MockRouter<InspectorRuntimeObjectRoute>()
    private let addSpecializationRelay = PublishRelay<Void>()
    private let selectSpecializationRelay = PublishRelay<InspectorSwiftSpecializationCellViewModel>()

    private let specializedWithInt = Fixtures.runtimeObject(name: "Box.Int", displayName: "Box<Int>", properties: [.isSpecialized])
    private let specializedWithString = Fixtures.runtimeObject(name: "Box.String", displayName: "Box<String>", properties: [.isSpecialized])
    private let nestedGeneric = Fixtures.runtimeObject(name: "Box.Inner", displayName: "Box.Inner", properties: [.isGeneric])

    @Test("specializedChildren lists only the specialized children, in declaration order")
    func specializedChildrenFiltersBySpecializedFlag() async throws {
        let box = Fixtures.runtimeObject(
            name: "Box",
            children: [specializedWithInt, nestedGeneric, specializedWithString],
            properties: [.isGeneric]
        )
        let (viewModel, output) = makeViewModel(for: box)
        defer { withExtendedLifetime(viewModel) {} }

        let rows = try await nextValue(from: output.specializedChildren)
        #expect(rows.map(\.runtimeObject) == [specializedWithInt, specializedWithString])
    }

    @Test("runtimeObjectDisplayName reflects the inspected object")
    func displayNameReflectsInspectedObject() {
        let box = Fixtures.runtimeObject(name: "Box", displayName: "Module.Box")
        let (viewModel, _) = makeViewModel(for: box)

        #expect(viewModel.runtimeObjectDisplayName == "Module.Box")
    }

    @Test("add specialization asks the router for the specialization sheet of the inspected object")
    func addSpecializationRequestsSheet() async throws {
        let box = Fixtures.runtimeObject(name: "Box", properties: [.isGeneric])
        let (viewModel, _) = makeViewModel(for: box)
        defer { withExtendedLifetime(viewModel) {} }

        addSpecializationRelay.accept(())
        try await settleMainQueue()

        guard case .requestSpecializationSheet(let requested)? = router.triggeredRoutes.last else {
            Issue.record("expected requestSpecializationSheet, got \(String(describing: router.triggeredRoutes.last))")
            return
        }
        #expect(requested == box)
    }

    @Test("selecting a specialization pushes it onto the document timeline")
    func selectingSpecializationPushesIt() async throws {
        let box = Fixtures.runtimeObject(name: "Box", children: [specializedWithInt], properties: [.isGeneric])
        let (viewModel, output) = makeViewModel(for: box)
        defer { withExtendedLifetime(viewModel) {} }
        let row = try #require(try await nextValue(from: output.specializedChildren).first)

        selectSpecializationRelay.accept(row)
        try await settleMainQueue()

        #expect(environment.documentState.selectedRuntimeObject == specializedWithInt)
        #expect(environment.documentState.selectionStack == [specializedWithInt])
        #expect(router.triggeredRoutes.isEmpty)
    }

    @Test("update(for:) swaps the rows to the new object's specialized children")
    func updateSwapsRows() async throws {
        let box = Fixtures.runtimeObject(name: "Box", children: [specializedWithInt], properties: [.isGeneric])
        let (viewModel, output) = makeViewModel(for: box)
        _ = try await nextValue(from: output.specializedChildren)

        let otherBox = Fixtures.runtimeObject(name: "Other", children: [specializedWithString], properties: [.isGeneric])
        viewModel.update(for: otherBox)

        let rows = try await nextValue(from: output.specializedChildren) { $0.map(\.runtimeObject) == [specializedWithString] }
        #expect(rows.count == 1)
        #expect(viewModel.runtimeObjectDisplayName == "Other")
    }

    @Test("update(for:) with the object already shown emits nothing")
    func updateWithSameObjectIsIgnored() async throws {
        let box = Fixtures.runtimeObject(name: "Box", children: [specializedWithInt], properties: [.isGeneric])
        let (viewModel, output) = makeViewModel(for: box)
        _ = try await nextValue(from: output.specializedChildren)

        async let emissions = values(from: output.specializedChildren.skip(1), during: 0.3)
        try await settleMainQueue()
        viewModel.update(for: box)

        #expect(try await emissions.isEmpty)
    }

    private func makeViewModel(for runtimeObject: RuntimeObject) -> (InspectorSwiftSpecializationViewModel, InspectorSwiftSpecializationViewModel.Output) {
        let viewModel = environment.make {
            InspectorSwiftSpecializationViewModel(runtimeObject: runtimeObject, documentState: environment.documentState, router: router)
        }
        let output = viewModel.transform(
            .init(
                addSpecializationClicked: addSpecializationRelay.asSignal(),
                selectSpecializationClicked: selectSpecializationRelay.asSignal()
            )
        )
        return (viewModel, output)
    }
}
