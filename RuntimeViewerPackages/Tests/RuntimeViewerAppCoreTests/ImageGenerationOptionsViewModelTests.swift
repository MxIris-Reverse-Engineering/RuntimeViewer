#if os(macOS)

import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettings
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// One image's Generation Options in the sheet Editor › Generation Options for “<image>”… opens,
/// and which image that menu item acts on (proposal `generation-options-image-overrides`).
@Suite("Image Generation Options")
@MainActor
struct ImageGenerationOptionsViewModelTests {
    private let environment = ViewModelTestEnvironment()

    private let otherImagePath = "/usr/lib/libOther.dylib"

    private var engine: RuntimeEngine { environment.documentState.runtimeEngine }

    private struct Harness {
        let viewModel: ImageGenerationOptionsViewModel
        let router: MockRouter<MainRoute>
        let appRouter: MockRouter<AppRoute>
        let updates: PublishRelay<GenerationOptionsMutation>
        let reverts: PublishRelay<Settings.GenerationOption>
        let revertAll: PublishRelay<Void>
        let showGlobalOptions: PublishRelay<Void>
        let done: PublishRelay<Void>
        let output: ImageGenerationOptionsViewModel.Output

        /// The overridden options once they satisfy `predicate`: the sheet hears the settings one
        /// main-queue turn after they change.
        func overriddenOptions(where predicate: @escaping (Set<Settings.GenerationOption>) -> Bool) async throws -> Set<Settings.GenerationOption> {
            try await nextValue(from: output.overriddenOptions, where: predicate)
        }
    }

    private func makeHarness(imagePath: String = Fixtures.sampleImagePath) -> Harness {
        let router = MockRouter<MainRoute>()
        let appRouter = MockRouter<AppRoute>()
        let viewModel = withDependencies {
            $0.appRouter = appRouter
        } operation: {
            environment.make { ImageGenerationOptionsViewModel(imagePath: imagePath, documentState: environment.documentState, router: router) }
        }
        let updates = PublishRelay<GenerationOptionsMutation>()
        let reverts = PublishRelay<Settings.GenerationOption>()
        let revertAll = PublishRelay<Void>()
        let showGlobalOptions = PublishRelay<Void>()
        let done = PublishRelay<Void>()
        let output = viewModel.transform(ImageGenerationOptionsViewModel.Input(
            updateOption: updates.asSignal(),
            revertOption: reverts.asSignal(),
            revertAll: revertAll.asSignal(),
            showGlobalOptions: showGlobalOptions.asSignal(),
            done: done.asSignal()
        ))
        return Harness(viewModel: viewModel, router: router, appRouter: appRouter, updates: updates, reverts: reverts, revertAll: revertAll, showGlobalOptions: showGlobalOptions, done: done, output: output)
    }

    // MARK: - Which image the menu item acts on

    @Test("the menu item acts on the image of the object the focused pane shows")
    func menuItemTargetsTheFocusedPanesImage() throws {
        let imageTree = Fixtures.imageTree(rootName: "Others", imagePaths: [Fixtures.sampleImagePath, otherImagePath])
        environment.documentState.selectionRouter.trigger(.switchImage(try #require(imageTree.leaf(forImagePath: otherImagePath))))
        environment.documentState.selectionRouter.trigger(.open(Fixtures.runtimeObject(imagePath: Fixtures.sampleImagePath), in: .focusedTab))

        #expect(environment.documentState.imagePathForGenerationOptions == Fixtures.sampleImagePath)

        environment.documentState.selectionRouter.trigger(.openImage(otherImagePath, in: .focusedTab))
        #expect(environment.documentState.imagePathForGenerationOptions == otherImagePath, "an image page acts on its image")
    }

    @Test("on an empty tab the menu item acts on the image the sidebar has open")
    func menuItemFallsBackToTheSidebarsImageOnAnEmptyTab() throws {
        let imageTree = Fixtures.imageTree(rootName: "Others", imagePaths: [Fixtures.sampleImagePath, otherImagePath])
        environment.documentState.selectionRouter.trigger(.switchImage(try #require(imageTree.leaf(forImagePath: otherImagePath))))

        #expect(environment.documentState.imagePathForGenerationOptions == otherImagePath)
    }

    @Test("without an image on screen or in the sidebar the menu item has nothing to act on")
    func menuItemIsDisabledWithoutAnImage() {
        #expect(environment.documentState.imagePathForGenerationOptions == nil)
    }

    // MARK: - The sheet

    @Test("the sheet shows the image's effective options and marks the overridden ones")
    func sheetShowsEffectiveValuesAndMarksOverriddenOptions() throws {
        environment.settings.generationOptions.global.objcHeaderOptions.stripOverrides = true
        environment.settings.generationOptions.updateOverride(forImageAt: Fixtures.sampleImagePath, in: engine) {
            $0.swiftInterfaceOptions.printFieldOffset = true
        }
        let harness = makeHarness()

        #expect(harness.viewModel.effectiveOptions.swiftInterfaceOptions.printFieldOffset)
        #expect(harness.viewModel.effectiveOptions.objcHeaderOptions.stripOverrides, "the options it does not override follow the global ones")
        #expect(harness.viewModel.overriddenOptions == [.swiftPrintFieldOffset])
    }

    @Test("changing an option in the sheet records it as the image's override, not a global change")
    func changingAnOptionInTheSheetRecordsAnOverride() async throws {
        let harness = makeHarness()

        harness.updates.accept { $0.swiftInterfaceOptions.memberSortOrder = .byOffset }

        #expect(environment.settings.generationOptions.effectiveOptions(forImageAt: Fixtures.sampleImagePath, in: engine).swiftInterfaceOptions.memberSortOrder == .byOffset)
        #expect(environment.settings.generationOptions.global.swiftInterfaceOptions.memberSortOrder == .byCategory)
        #expect(try await harness.overriddenOptions { !$0.isEmpty } == [.swiftMemberSortOrder])
        #expect(environment.settings.generationOptions.effectiveOptions(forImageAt: otherImagePath, in: engine).swiftInterfaceOptions.memberSortOrder == .byCategory)
    }

    @Test("reverting an option puts it back on the global value, and the others stay")
    func revertingAnOptionReturnsItToTheGlobalValue() async throws {
        let harness = makeHarness()
        harness.updates.accept {
            $0.swiftInterfaceOptions.printFieldOffset = true
            $0.swiftInterfaceOptions.expandsMacros = true
        }
        _ = try await harness.overriddenOptions { $0.count == 2 }

        harness.reverts.accept(.swiftPrintFieldOffset)

        #expect(try await harness.overriddenOptions { $0.count == 1 } == [.swiftExpandsMacros])
        #expect(!harness.viewModel.effectiveOptions.swiftInterfaceOptions.printFieldOffset)
        #expect(harness.viewModel.effectiveOptions.swiftInterfaceOptions.expandsMacros)
    }

    @Test("Revert All puts every option of the image back on the global ones")
    func revertAllRemovesTheImagesOverride() async throws {
        let harness = makeHarness()
        harness.updates.accept {
            $0.swiftInterfaceOptions.printFieldOffset = true
            $0.objcHeaderOptions.addIvarOffsetComments = true
        }
        #expect(try await nextValue(from: harness.output.canRevertAll) { $0 })

        harness.revertAll.accept(())

        #expect(environment.settings.generationOptions.imageOverrides.isEmpty)
        #expect(try await harness.overriddenOptions { $0.isEmpty }.isEmpty)
        #expect(try await nextValue(from: harness.output.canRevertAll) { !$0 } == false)
        #expect(harness.viewModel.effectiveOptions == environment.settings.generationOptions.global)
    }

    @Test("the sheet follows a change of the global options made in Settings while it is open")
    func sheetFollowsGlobalChangesMadeInSettings() async throws {
        let harness = makeHarness()

        environment.settings.generationOptions.global.objcHeaderOptions.addMethodIMPAddressComments = true

        let options = try await nextValue(from: harness.output.options) { $0.objcHeaderOptions.addMethodIMPAddressComments }
        #expect(options.objcHeaderOptions.addMethodIMPAddressComments)
        #expect(harness.viewModel.overriddenOptions.isEmpty, "a global change is no override")
    }

    @Test("Global Options… opens Settings › Generation Options, and Done closes the sheet")
    func globalOptionsOpensTheSettingsPage() {
        let harness = makeHarness()

        harness.showGlobalOptions.accept(())
        harness.done.accept(())

        #expect(harness.appRouter.triggeredRoutes.count == 1)
        if case .settingsPage(let page)? = harness.appRouter.triggeredRoutes.first {
            #expect(page == .generationOptions)
        } else {
            Issue.record("expected the Generation Options page, got \(harness.appRouter.triggeredRoutes)")
        }
        #expect(harness.router.triggeredRoutes.count == 1)
        if case .dismiss? = harness.router.triggeredRoutes.first {} else {
            Issue.record("expected the sheet to be dismissed, got \(harness.router.triggeredRoutes)")
        }
    }
}

#endif
