import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore

/// The lists that offer the runtime object commands carry out the ones their
/// menus report (proposal `context-menus`).
@Suite("RuntimeObjectAction wiring")
@MainActor
struct RuntimeObjectActionWiringTests {
    @Test("a sidebar row's command is carried out")
    func sidebarRowCommandIsCarriedOut() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let tree = Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc])
        let leaf = try #require(tree.leaf(forImagePath: TestImages.libobjc))
        let router = MockRouter<SidebarRuntimeObjectRoute>()
        let viewModel = environment.make {
            SidebarRuntimeObjectListViewModel(imageNode: leaf, documentState: environment.documentState, router: router)
        }
        defer { withExtendedLifetime(viewModel) {} }
        let actionRelay = PublishRelay<RuntimeObjectActionRequest>()
        _ = viewModel.transform(
            SidebarRuntimeObjectViewModel.Input(
                runtimeObjectClicked: .empty(),
                runtimeObjectOpenedInNewTab: .empty(),
                loadImageClicked: .empty(),
                filter: .just(.empty),
                isSearchCaseSensitive: .just(false),
                runtimeObjectActionRequested: actionRelay.asSignal()
            )
        )
        let nsObject = try await Self.nsObject(in: engine)

        actionRelay.accept(RuntimeObjectActionRequest(action: .copyName, runtimeObject: nsObject))

        // The sidebar's handlers run in a main-actor task of their own.
        try await waitUntil { !environment.pasteboard.copiedStrings.isEmpty }
        #expect(environment.pasteboard.copiedStrings == [nsObject.displayName])
    }

    @Test("an Inspector row's command, or a modified click on it, is carried out")
    func inspectorRowCommandIsCarriedOut() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let nsObject = try await Self.nsObject(in: engine)
        environment.documentState.selectionRouter.trigger(.open(nsObject, in: .focusedTab))
        _ = try await nextValue(from: environment.documentState.$editorArea) { $0.focusedPane.tabs.count == 1 }
        let router = MockRouter<InspectorRuntimeObjectRoute>()
        let viewModel = environment.make {
            InspectorRelationshipsViewModel(runtimeObject: nsObject, documentState: environment.documentState, router: router)
        }
        defer { withExtendedLifetime(viewModel) {} }
        let actionRelay = PublishRelay<RuntimeObjectActionRequest>()
        _ = viewModel.transform(InspectorRelationshipsViewModel.Input(selectRelationshipClicked: .empty(), runtimeObjectActionRequested: actionRelay.asSignal()))

        actionRelay.accept(RuntimeObjectActionRequest(action: .openInNewTab, runtimeObject: nsObject))

        let editorArea = try await nextValue(from: environment.documentState.$editorArea) { $0.focusedPane.tabs.count == 2 }
        #expect(editorArea.focusedPane.tabs[1].object == nsObject)
    }

    @Test("a modified click stands for the command that opens the row there")
    func modifiedClickStandsForTheOpeningCommand() {
        let nsObject = Fixtures.runtimeObject(name: "NSObject", kind: .objc(.type(.class)), imagePath: TestImages.libobjc)

        #expect(RuntimeObjectAction(opening: .focusedTab) == nil)
        #expect(RuntimeObjectAction(opening: .newTab) == .openInNewTab)
        #expect(RuntimeObjectAction(opening: .nextEditorPane) == .openInNextEditorPane)
        #expect(RuntimeObjectActionRequest(action: .openInNewTab, runtimeObject: nsObject).runtimeObject == nsObject)
    }

    private static func nsObject(in engine: RuntimeEngine) async throws -> RuntimeObject {
        let objects = try await engine.objects(in: TestImages.libobjc)
        return try #require(objects.first { $0.name == "NSObject" && $0.kind == .objc(.type(.class)) })
    }
}
