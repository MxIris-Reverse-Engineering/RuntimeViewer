#if os(macOS)

import Foundation
import Testing
import Dependencies
import RuntimeViewerArchitectures
import RuntimeViewerCore
@testable import RuntimeViewerEngineManagement
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// Where Load Frameworks loads, by the engine of the window (proposal
/// `isolated-framework-loading`): My Mac opens a window on a new instance, a
/// framework instance loads into itself, other engines into their process, a
/// file not at all; and a refusal in a window showing something is a sheet.
@Suite("Main window Load Frameworks")
@MainActor
struct MainViewModelLoadFrameworksTests {
    private static let frameworkURLs = [URL(fileURLWithPath: "/usr/bin/true")]

    private struct Fixture {
        let environment: ViewModelTestEnvironment
        let router: MockRouter<MainRoute>
        let manager: RuntimeEngineManager
        let viewModel: MainViewModel
        let output: MainViewModel.Output
        let frameworksSelected: PublishRelay<[URL]>
        let loadedImagePaths: LoadedImagePaths
    }

    @MainActor
    private final class LoadedImagePaths {
        var paths: [String] = []
        var refuses = false
    }

    private static func makeFixture(on engine: RuntimeEngine?) -> Fixture {
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let router = MockRouter<MainRoute>()
        let manager = RuntimeEngineManager(configuration: .application, startupHandler: { _ in })
        let loadedImagePaths = LoadedImagePaths()
        environment.documentState.frameworkLoader.imageLoading = FrameworkLoader.ImageLoading(
            loadImage: { _, imagePath in
                loadedImagePaths.paths.append(imagePath)
                if loadedImagePaths.refuses {
                    throw RuntimeImageLoadError(
                        dyldMessage: "dlopen(\(imagePath), 0x0001): tried: '\(imagePath)' (no such file)",
                        diagnosis: RuntimeImageLoadDiagnosis(dyldMessage: "dlopen(\(imagePath), 0x0001): tried: '\(imagePath)' (no such file)", imagePath: imagePath)
                    )
                }
            },
            diagnoseImageLoad: { _, diagnosis, _, _ in diagnosis },
            waitUntilReady: { _ in }
        )
        let viewModel = withDependencies {
            $0.runtimeEngineManager = manager
        } operation: {
            environment.make { MainViewModel(documentState: environment.documentState, router: router) }
        }
        let frameworksSelected = PublishRelay<[URL]>()
        let output = viewModel.transform(MainViewModel.Input(
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
            frameworksSelected: frameworksSelected.asSignal(),
            saveLocationSelected: .empty(),
            dependencyCacheSelected: .empty()
        ))
        return Fixture(environment: environment, router: router, manager: manager, viewModel: viewModel, output: output, frameworksSelected: frameworksSelected, loadedImagePaths: loadedImagePaths)
    }

    private static func frameworkInstanceEngine() -> RuntimeEngine {
        RuntimeEngine(
            source: .frameworkInstance(name: "Foo.framework (Isolated)", frameworkURL: URL(fileURLWithPath: "/A/Foo.framework"), identifier: .init(rawValue: UUID().uuidString)),
            engineID: "MainViewModelLoadFrameworksTests.\(UUID().uuidString)"
        )
    }

    @Test("on My Mac the frameworks go to a window of their own on a new instance")
    func loadFrameworksOnMyMacOpensAnIsolatedWindow() {
        let fixture = Self.makeFixture(on: nil)
        defer { withExtendedLifetime(fixture) {} }

        fixture.frameworksSelected.accept(Self.frameworkURLs)

        let opened = fixture.router.triggeredRoutes.compactMap { route -> [URL]? in
            if case .openIsolatedFrameworks(let urls) = route { return urls }
            return nil
        }
        #expect(opened == [Self.frameworkURLs])
        #expect(fixture.loadedImagePaths.paths.isEmpty)
    }

    @Test("on a framework instance the frameworks load into it")
    func loadFrameworksOnAFrameworkInstanceLoadsInPlace() async {
        let fixture = Self.makeFixture(on: Self.frameworkInstanceEngine())
        defer { withExtendedLifetime(fixture) {} }

        fixture.frameworksSelected.accept(Self.frameworkURLs)

        let loaded = await pollUntil(timeout: .seconds(10)) { !fixture.loadedImagePaths.paths.isEmpty }
        #expect(loaded)
        #expect(!fixture.router.triggeredRoutes.contains { $0.isOpenIsolatedFrameworks })
    }

    @Test("on an injected process the frameworks load into that process, and a refusal is a sheet without remedies")
    func loadFrameworksOnAnInjectedProcessLoadsInPlaceWithoutRemedies() async {
        let engine = RuntimeEngine(source: .localSocket(name: "Injected", identifier: "4242", role: .client), engineID: "MainViewModelLoadFrameworksTests.\(UUID().uuidString)")
        let fixture = Self.makeFixture(on: engine)
        defer { withExtendedLifetime(fixture) {} }
        fixture.loadedImagePaths.refuses = true

        fixture.frameworksSelected.accept(Self.frameworkURLs)

        let presented = await pollUntil(timeout: .seconds(10)) { fixture.router.triggeredRoutes.contains { $0.isFrameworkLoadFailure } }
        #expect(presented)
        guard case .failed(let failure) = fixture.environment.documentState.frameworkLoader.state else {
            Issue.record("not failed")
            return
        }
        #expect(!failure.offersRemedies)
    }

    @Test("on a file Load Frameworks does nothing, and the button is off")
    func loadFrameworksIsDisabledOnAFile() async throws {
        let engine = RuntimeEngine(source: .file(name: "true", url: URL(fileURLWithPath: "/usr/bin/true")), engineID: "MainViewModelLoadFrameworksTests.\(UUID().uuidString)")
        let fixture = Self.makeFixture(on: engine)
        defer { withExtendedLifetime(fixture) {} }

        fixture.frameworksSelected.accept(Self.frameworkURLs)

        #expect(try await nextValue(from: fixture.output.isLoadFrameworksEnabled) == false)
        #expect(fixture.router.triggeredRoutes.isEmpty)
        #expect(fixture.loadedImagePaths.paths.isEmpty)
    }

    @Test("a refusal in a framework instance window that shows nothing stays in its panes")
    func refusalInAnEmptyInstanceWindowIsNoSheet() async {
        let fixture = Self.makeFixture(on: Self.frameworkInstanceEngine())
        defer { withExtendedLifetime(fixture) {} }
        fixture.loadedImagePaths.refuses = true

        fixture.frameworksSelected.accept(Self.frameworkURLs)

        let failed = await pollUntil(timeout: .seconds(10)) {
            if case .failed = fixture.environment.documentState.frameworkLoader.state { return true }
            return false
        }
        #expect(failed)
        #expect(!fixture.router.triggeredRoutes.contains { $0.isFrameworkLoadFailure })
    }

    @Test("a framework instance window is titled after its first framework, says how its load stands, and its button says where frameworks go")
    func frameworkInstanceWindowTitle() async throws {
        let fixture = Self.makeFixture(on: Self.frameworkInstanceEngine())
        defer { withExtendedLifetime(fixture) {} }

        #expect(try await nextValue(from: fixture.output.toolbarTitle) == "Foo.framework")
        #expect(try await nextValue(from: fixture.output.toolbarSubtitle) == "Isolated")
        #expect(try await nextValue(from: fixture.output.loadFrameworksToolTip) == "Load Frameworks into This Instance")
    }

    @Test("on My Mac the button says the frameworks go to a new instance")
    func myMacToolTip() async throws {
        let fixture = Self.makeFixture(on: nil)
        defer { withExtendedLifetime(fixture) {} }

        #expect(try await nextValue(from: fixture.output.loadFrameworksToolTip) == "Load Frameworks in a New Isolated Instance")
        #expect(try await nextValue(from: fixture.output.toolbarTitle) == "RuntimeViewer")
    }
}

#endif
