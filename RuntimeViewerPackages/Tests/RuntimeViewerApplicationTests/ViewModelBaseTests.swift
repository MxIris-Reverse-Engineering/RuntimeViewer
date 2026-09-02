import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The two placeholder ViewModels add nothing to `ViewModel<Route>`, so they
/// double as the concrete subjects for the base class's own contract.
@Suite("ViewModel base class")
@MainActor
struct ViewModelBaseTests {
    private let environment = ViewModelTestEnvironment()
    private let contentRouter = MockRouter<ContentRoute>()
    private let inspectorRouter = MockRouter<InspectorRoute>()

    @Test("placeholder view models keep the document state and router they were created with")
    func placeholdersKeepCollaborators() {
        let (contentViewModel, inspectorViewModel) = environment.make {
            (
                ContentPlaceholderViewModel(documentState: environment.documentState, router: contentRouter),
                InspectorPlaceholderViewModel(documentState: environment.documentState, router: inspectorRouter)
            )
        }

        #expect(contentViewModel.documentState === environment.documentState)
        #expect(contentViewModel.router === contentRouter)
        #expect(inspectorViewModel.documentState === environment.documentState)
        #expect(inspectorViewModel.router === inspectorRouter)
    }

    @Test("currentMergedGenerationOptions is the stored options with the live transformer settings applied")
    func mergedOptionsCombineStoredOptionsAndTransformer() {
        let viewModel = makePlaceholder()

        var expected = environment.appDefaults.options
        expected.transformer = environment.settings.transformer

        #expect(viewModel.currentMergedGenerationOptions == expected)
    }

    @Test("commonLoading is false until tracked work starts and false again once it ends")
    func commonLoadingFollowsTrackedActivity() async throws {
        let viewModel = makePlaceholder()
        #expect(try await nextValue(from: viewModel.commonLoading) == false)

        let inFlightWork = Observable<Never>.never().trackActivity(viewModel._commonLoading).subscribe()
        #expect(try await nextValue(from: viewModel.commonLoading, where: { $0 }) == true)

        inFlightWork.dispose()
        #expect(try await nextValue(from: viewModel.commonLoading, where: { !$0 }) == false)
    }

    @Test("delayedLoading never reports work that finishes within half a second")
    func delayedLoadingIgnoresShortWork() async throws {
        let viewModel = makePlaceholder()
        async let observed = values(from: viewModel.delayedLoading, during: 0.9)
        try await settleMainQueue()

        let inFlightWork = Observable<Never>.never().trackActivity(viewModel._commonLoading).subscribe()
        try await Task.sleep(for: .milliseconds(150))
        inFlightWork.dispose()

        #expect(try await observed.contains(true) == false)
    }

    @Test("delayedLoading reports work that outlives the half-second grace period")
    func delayedLoadingReportsLongWork() async throws {
        let viewModel = makePlaceholder()
        async let quietWindow = values(from: viewModel.delayedLoading, during: 0.4)
        try await settleMainQueue()

        let inFlightWork = Observable<Never>.never().trackActivity(viewModel._commonLoading).subscribe()
        defer { inFlightWork.dispose() }

        #expect(try await quietWindow.contains(true) == false)
        #expect(try await nextValue(from: viewModel.delayedLoading, where: { $0 }) == true)
    }

    private func makePlaceholder() -> ContentPlaceholderViewModel {
        environment.make {
            ContentPlaceholderViewModel(documentState: environment.documentState, router: contentRouter)
        }
    }
}
