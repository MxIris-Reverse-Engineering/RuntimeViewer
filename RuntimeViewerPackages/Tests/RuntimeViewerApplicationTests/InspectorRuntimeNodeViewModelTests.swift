import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("InspectorRuntimeNodeViewModel")
@MainActor
struct InspectorRuntimeNodeViewModelTests {
    private let environment = ViewModelTestEnvironment()
    private let router = MockRouter<InspectorRoute>()

    @Test("exposes the image node it was created for")
    func exposesRuntimeNode() {
        let tree = Fixtures.imageTree(rootName: "Root", imagePaths: [TestImages.libobjc])
        let viewModel = environment.make {
            InspectorRuntimeNodeViewModel(runtimeNode: tree, documentState: environment.documentState, router: router)
        }

        #expect(viewModel.runtimeNode === tree)
        #expect(viewModel.documentState === environment.documentState)
    }
}
