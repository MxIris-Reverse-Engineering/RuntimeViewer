import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// End-to-end behaviour of the content pane against a real engine. The
/// fetch/render split itself, fetch counting and failure recovery are pinned
/// with an injected provider in `ContentTextPipelineTests`.
@Suite("ContentTextViewModel")
@MainActor
struct ContentTextViewModelTests {
    private let router = MockRouter<ContentRoute>()
    private let runtimeObjectClickedRelay = PublishRelay<RuntimeObject>()
    private let runtimeObjectOpenedInNewTabRelay = PublishRelay<RuntimeObject>()

    @Test("renders the shown object's interface and names its image")
    func rendersInterface() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let nsString = try await engine.runtimeObject(named: "NSString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: nsString, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let rendered = try await nextValue(from: output.renderedInterface, timeout: 120)
        #expect(rendered.attributedString.string.contains("@interface NSString"))
        #expect(try await nextValue(from: output.attributedString).string == rendered.attributedString.string)
        #expect(try await nextValue(from: output.imageNameOfRuntimeObject) == "Foundation")
        _ = try await nextValue(from: output.theme)
    }

    @Test("selectedRuntimeObjectName follows the document's selection")
    func selectedNameFollowsDocument() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let nsObject = try await engine.runtimeObject(named: "NSObject", kind: .objc(.type(.class)), in: TestImages.libobjc)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: nsObject, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        #expect(try await nextValue(from: output.selectedRuntimeObjectName) == "")

        environment.documentState.selectionRouter.trigger(.push(nsObject))

        #expect(try await nextValue(from: output.selectedRuntimeObjectName) { !$0.isEmpty } == "NSObject")
    }

    @Test("clicking a type link resolves it through the engine and pushes it")
    func clickingLinkPushesResolvedObject() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let nsObject = try await engine.runtimeObject(named: "NSObject", kind: .objc(.type(.class)), in: TestImages.libobjc)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, _) = makeViewModel(for: nsObject, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        runtimeObjectClickedRelay.accept(nsObject)

        let selected = try await nextValue(from: environment.documentState.$selectedRuntimeObject, timeout: 60) { $0 != nil }
        #expect(selected?.name == "NSObject")
        #expect(environment.documentState.tabs.count == 1)
    }

    @Test("opening a type link in a new tab adds an active tab showing it")
    func openingLinkInNewTabAddsTab() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let nsObject = try await engine.runtimeObject(named: "NSObject", kind: .objc(.type(.class)), in: TestImages.libobjc)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, _) = makeViewModel(for: nsObject, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        runtimeObjectOpenedInNewTabRelay.accept(nsObject)

        let tabs = try await nextValue(from: environment.documentState.$tabs, timeout: 60) { $0.count == 2 }
        #expect(environment.documentState.activeTabIndex == 1)
        #expect(tabs[1].object?.name == "NSObject")
    }

    @Test("a type link the engine cannot resolve reports runtimeObjectNotFound instead of navigating")
    func unresolvableLinkReportsNotFound() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let nsObject = try await engine.runtimeObject(named: "NSObject", kind: .objc(.type(.class)), in: TestImages.libobjc)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(for: nsObject, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        async let notFound: Void = nextValue(from: output.runtimeObjectNotFound, timeout: 60)
        try await settleMainQueue()

        runtimeObjectClickedRelay.accept(
            Fixtures.runtimeObject(name: "RuntimeViewerApplicationTestsMissingClass", kind: .objc(.type(.class)))
        )

        try await notFound
        #expect(environment.documentState.selectedRuntimeObject == nil)
    }

    // MARK: - Helpers

    private func makeViewModel(
        for runtimeObject: RuntimeObject,
        in environment: ViewModelTestEnvironment
    ) -> (ContentTextViewModel, ContentTextViewModel.Output) {
        let viewModel = environment.make {
            ContentTextViewModel(runtimeObject: runtimeObject, documentState: environment.documentState, router: router)
        }
        let output = viewModel.transform(
            .init(
                runtimeObjectClicked: runtimeObjectClickedRelay.asSignal(),
                runtimeObjectOpenedInNewTab: runtimeObjectOpenedInNewTabRelay.asSignal()
            )
        )
        return (viewModel, output)
    }
}
