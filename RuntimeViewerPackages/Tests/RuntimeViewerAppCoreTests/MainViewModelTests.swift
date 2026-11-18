#if os(macOS)

import Foundation
import Testing
import Dependencies
import RuntimeViewerArchitectures
import RuntimeViewerCore
@testable import RuntimeViewerEngineManagement
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The document window's view model describes the toolbar's icons as values — the title's, the
/// history menus', the runtime source pickers' — and the window controller draws them.
@Suite("Main window view model")
@MainActor
struct MainViewModelTests {
    @Test("the title shows the app's own symbol while no image is open")
    func titleIconIsApplicationWithoutImage() {
        #expect(MainViewModel.toolbarIcon(for: nil) == .application)
    }

    @Test("the title shows the kind of the image it names")
    func titleIconFollowsImageKind() throws {
        let imagePath = "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"
        let imageNode = try #require(Fixtures.imageTree(rootName: "Dyld Shared Cache", imagePaths: [imagePath]).leaf(forImagePath: imagePath))

        #expect(MainViewModel.toolbarIcon(for: imageNode) == .imageKind(imageNode.kind))
    }

    @Test("a history step describes an object's glyph at the menus' size, and an image's kind")
    func historyItemsDescribeObjectAndImageIcons() {
        let object = Fixtures.runtimeObject(name: "SampleClass", kind: .swift(.type(.class)))
        let imagePath = "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"

        let objectItem = MainViewModel.historyItem(for: NavigationEntry(object: object), at: 0)
        let imageItem = MainViewModel.historyItem(for: NavigationEntry(imagePath: imagePath), at: 1)

        #expect(objectItem.icon == .runtimeObject(object.kind, size: NavigationHistorySnapshot.iconSize))
        #expect(objectItem.index == 0)
        #expect(imageItem.icon == .imageKind(RuntimeImageKind(ofImageAt: imagePath)))
        #expect(imageItem.index == 1)
    }

    @Test("an Objective-C object shown as Swift is a step of its own, named as its Generated Interface")
    func historyTitleMarksGeneratedInterface() {
        let object = Fixtures.runtimeObject(name: "NSSample", kind: .objc(.type(.class)))

        let ownLanguageItem = MainViewModel.historyItem(for: NavigationEntry(object: object), at: 0)
        let generatedInterfaceItem = MainViewModel.historyItem(for: NavigationEntry(object: object, interfaceLanguage: .swift), at: 1)

        #expect(ownLanguageItem.displayName == "NSSample")
        #expect(generatedInterfaceItem.displayName == "NSSample (Generated Interface)")
    }

    @Test("the runtime source picker describes every source's icon by its engine, the window's own source included")
    func sourcePickerContentDescribesEngineIcons() async throws {
        let environment = ViewModelTestEnvironment()
        let router = MockRouter<MainRoute>()
        let manager = RuntimeEngineManager(configuration: .application, startupHandler: { _ in })
        let viewModel = withDependencies {
            $0.runtimeEngineManager = manager
        } operation: {
            environment.make { MainViewModel(documentState: environment.documentState, router: router) }
        }
        defer { withExtendedLifetime((viewModel, router, manager)) {} }
        let output = viewModel.transform(Self.emptyInput)

        let state = try await nextValue(from: output.switchSourceState)
        let content = try await nextValue(from: output.runtimeSourcePickerContent)

        #expect(state.icon == .runtimeEngine(engineID: state.selectedEngineIdentifier))
        for source in content.sections.flatMap(\.sources) {
            #expect(source.icon == .runtimeEngine(engineID: source.engineIdentifier))
        }
        if let disconnectedSource = content.disconnectedSource {
            #expect(disconnectedSource.icon == .runtimeEngine(engineID: state.selectedEngineIdentifier))
        }
    }

    @Test("while its engine is gone, the window's source is listed by its engine's icon, checked and not a choice")
    func disconnectedSourceKeepsEngineIconDescriptor() async throws {
        let departedEngine = RuntimeEngine(source: .local, engineID: "MainViewModelTests.departed")
        let environment = ViewModelTestEnvironment(runtimeEngine: departedEngine)
        let router = MockRouter<MainRoute>()
        let manager = RuntimeEngineManager(configuration: .application, startupHandler: { _ in })
        let viewModel = withDependencies {
            $0.runtimeEngineManager = manager
        } operation: {
            environment.make { MainViewModel(documentState: environment.documentState, router: router) }
        }
        defer { withExtendedLifetime((viewModel, router, manager, departedEngine)) {} }
        let output = viewModel.transform(Self.emptyInput)

        let state = try await nextValue(from: output.switchSourceState)
        let content = try await nextValue(from: output.runtimeSourcePickerContent)

        #expect(state.isDisconnected)
        #expect(state.title.hasSuffix("(Disconnected)"))
        #expect(state.icon == .runtimeEngine(engineID: "MainViewModelTests.departed"))
        let disconnectedSource = try #require(content.disconnectedSource)
        #expect(disconnectedSource.icon == .runtimeEngine(engineID: "MainViewModelTests.departed"))
        #expect(disconnectedSource.isCurrent)
        #expect(disconnectedSource.isEnabled == false)
    }

    private static var emptyInput: MainViewModel.Input {
        MainViewModel.Input(
            sidebarBackClick: .empty(),
            navigationPreviousClick: .empty(),
            navigationNextClick: .empty(),
            navigationHistorySelected: .empty(),
            saveClick: .empty(),
            switchSource: .empty(),
            generationOptionsClick: .empty(),
            increaseFontSize: .empty(),
            decreaseFontSize: .empty(),
            resetFontSize: .empty(),
            loadFrameworksClick: .empty(),
            attachToProcessClick: .empty(),
            mcpStatusClick: .empty(),
            activityClick: .empty(),
            frameworksSelected: .empty(),
            saveLocationSelected: .empty(),
            dependencyCacheSelected: .empty()
        )
    }
}

#endif
