import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The commands every context menu offers on a runtime object, and what each
/// does (draft-context-menus).
@Suite("RuntimeObjectAction")
@MainActor
struct RuntimeObjectActionTests {
    private let router = MockRouter<InspectorRoute>()

    @Test("an Objective-C class offers every command, in menu order")
    func objectiveCClassOffersEveryCommand() {
        let nsObject = Fixtures.runtimeObject(name: "NSObject", kind: .objc(.type(.class)), imagePath: TestImages.libobjc)

        #expect(RuntimeObjectAction.actions(for: nsObject) == [.openInNewTab, .openInNextEditorPane, .openGeneratedInterface, .findTypeReferences, .copyName])
    }

    @Test("an Objective-C protocol has a Generated Interface but no type references")
    func objectiveCProtocolHasNoTypeReferences() {
        let nsCopying = Fixtures.runtimeObject(name: "NSCopying", kind: .objc(.type(.protocol)), imagePath: TestImages.libobjc)

        #expect(RuntimeObjectAction.actions(for: nsCopying) == [.openInNewTab, .openInNextEditorPane, .openGeneratedInterface, .copyName])
    }

    @Test("a Swift struct has type references but no Generated Interface")
    func swiftStructHasNoGeneratedInterface() {
        let url = Fixtures.runtimeObject(name: "10Foundation3URLV", kind: .swift(.type(.struct)), imagePath: TestImages.foundation)

        #expect(RuntimeObjectAction.actions(for: url) == [.openInNewTab, .openInNextEditorPane, .findTypeReferences, .copyName])
    }

    @Test("Open in New Tab opens the object in a new tab of the focused pane")
    func openInNewTabOpensANewTab() async throws {
        let harness = try await Harness.make(router: router)
        defer { withExtendedLifetime(harness.viewModel) {} }
        let nsObject = try await harness.nsObject()
        harness.environment.documentState.selectionRouter.trigger(.open(nsObject, in: .focusedTab))
        _ = try await nextValue(from: harness.environment.documentState.$editorArea) { $0.focusedPane.tabs.count == 1 }

        harness.viewModel.perform(.openInNewTab, on: nsObject)

        let editorArea = try await nextValue(from: harness.environment.documentState.$editorArea) { $0.focusedPane.tabs.count == 2 }
        #expect(editorArea.focusedPane.tabs[1].object == nsObject)
    }

    @Test("Find Type References runs the command in the Find session")
    func findTypeReferencesRunsTheCommand() async throws {
        let harness = try await Harness.make(router: router)
        defer { withExtendedLifetime(harness.viewModel) {} }
        let nsObject = try await harness.nsObject()
        // Made inside the environment, so it records into the environment's defaults.
        let session = harness.environment.make { harness.environment.documentState.findSession }

        harness.viewModel.perform(.findTypeReferences, on: nsObject)

        #expect(session.query.mode == .typeReferences)
        #expect(session.query.crossReferenceRoot == .type(nsObject))
    }

    @Test("Copy Name puts the listed name on the pasteboard")
    func copyNameCopiesTheListedName() async throws {
        let harness = try await Harness.make(router: router)
        defer { withExtendedLifetime(harness.viewModel) {} }
        let nsObject = try await harness.nsObject()

        harness.viewModel.perform(.copyName, on: nsObject)

        #expect(harness.environment.pasteboard.copiedStrings == [nsObject.displayName])
    }

    // MARK: - Helpers

    /// A view model to carry the commands out on: any will do, as they all
    /// inherit `perform(_:on:)`.
    @MainActor
    private struct Harness {
        let environment: ViewModelTestEnvironment
        let viewModel: InspectorPlaceholderViewModel

        static func make(router: MockRouter<InspectorRoute>) async throws -> Harness {
            let engine = try await TestRuntimeEngine.shared()
            let environment = ViewModelTestEnvironment(runtimeEngine: engine)
            let viewModel = environment.make {
                InspectorPlaceholderViewModel(documentState: environment.documentState, router: router)
            }
            return Harness(environment: environment, viewModel: viewModel)
        }

        func nsObject() async throws -> RuntimeObject {
            let objects = try await environment.documentState.runtimeEngine.objects(in: TestImages.libobjc)
            return try #require(objects.first { $0.name == "NSObject" && $0.kind == .objc(.type(.class)) })
        }
    }
}
