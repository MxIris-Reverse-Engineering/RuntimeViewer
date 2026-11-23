import AppKit
import Foundation
import Dependencies
import RxSwift
@testable import RuntimeViewerCore
@testable import RuntimeViewerSettings
import RuntimeViewerArchitectures
import Semantic
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// Regression suite for the split content-text pipeline
/// (`ContentTextViewModel`'s fetch half vs. render half).
///
/// History: before the 2026-08 split, the interface fetch and the attributed
/// string build lived in a single `combineLatest` that also observed the
/// theme — so every theme / font-size change re-fetched the interface over
/// XPC and rebuilt the whole attributed string on the main thread, and a
/// trailing `catchAndReturn` on the outer chain completed the pipeline on
/// the first fetch error, permanently freezing the tab. A failed fetch must
/// not kill the pipeline, which this suite pins.
///
/// Since proposal `app-core-without-ui-models` the theme is not the view
/// model's at all: the view themes the interface (`ContentTextRenderer`, whose
/// tests in RuntimeViewerAppUITests pin that a theme change re-themes without a
/// refetch), and the view model's loading lasts until the view reports the
/// interface displayed, which this suite pins too.
@Suite("ContentTextPipeline", .serialized)
@MainActor
struct ContentTextPipelineTests {
    /// In-memory settings for this suite, injected in place of the live ones.
    ///
    /// **Not a convenience — the live value writes to the developer's own
    /// settings file.** `Settings.store` picks its directory at compile time
    /// (`#if DEBUG` → `RuntimeViewer-Debug`), and `swift test` builds in Debug,
    /// so the live `SettingsAccess` in a test run is backed by the very
    /// `~/Library/Application Support/RuntimeViewer-Debug/settings.json` the
    /// Debug app uses. Nothing in a test process calls `load()` — loading is a
    /// deliberate step in `SettingsLifecycleController`, not a side effect of
    /// resolving `@Dependency(\.settings)` — so that store holds a *default*
    /// `Settings`. Writing `theme.fontSize` below would then trip the store's
    /// one-second auto-save and flush those defaults over the real file,
    /// silently resetting the developer's Debug settings. It has happened.
    ///
    /// **`static`.** swift-testing builds a fresh suite value per `@Test`, so a
    /// stored property would hand each case a store of its own; one store per
    /// process keeps whatever captures the settings once pointed at the same
    /// object as the assertions.
    ///
    /// `makeViewModel` creates the view model inside
    /// `withLiveDependencyContext`, so the pipeline inherits this instance and
    /// observes the writes the assertions make.
    @MainActor
    private static let testSettings = SettingsAccess.preview

    // MARK: - The loading indicator lasts until the view shows the interface

    /// The view themes the text after the view model hands the interface over (RuntimeViewerAppUI's
    /// `ContentTextRenderer`), so the loading the view model tracks lasts until the view reports the
    /// interface displayed: ending at the hand-over would leave the plate off while the text is still
    /// being themed (proposal `app-core-without-ui-models`).
    @Test("loading stays on until the view reports the interface displayed")
    func loadingStaysOnUntilTheViewReportsTheInterfaceDisplayed() async throws {
        let interfaceDisplayedRelay = PublishRelay<ContentInterface.ID>()
        let (viewModel, mockRouter) = makeViewModel(
            runtimeObject: makeRuntimeObject(),
            interfaceProvider: { runtimeObject, _ in
                RuntimeObjectInterface(object: runtimeObject, interfaceString: "class ContentPipelineFixture {}")
            }
        )
        _ = viewModel.transform(Self.input(reportingDisplayedWith: interfaceDisplayedRelay))
        let loadingRecorder = LoadingStateRecorder()
        let subscriptionDisposeBag = DisposeBag()
        viewModel._commonLoading.asDriver()
            .driveOnNext { isLoading in
                loadingRecorder.record(isLoading)
            }
            .disposed(by: subscriptionDisposeBag)

        let prepared = try await pollUntil(timeout: .seconds(10)) {
            viewModel.interface != nil
        }
        #expect(prepared, "the interface never reached the view model")
        let interface = try #require(viewModel.interface)
        // Well past the hand-over, and nothing has reported the interface displayed.
        try await Task.sleep(for: .milliseconds(300))
        #expect(loadingRecorder.isLoading, "the loading ended before the view reported the interface displayed")

        interfaceDisplayedRelay.accept(interface.id)
        let ended = try await pollUntil(timeout: .seconds(5)) {
            !loadingRecorder.isLoading
        }
        #expect(ended, "the report of the interface on screen did not end the loading")

        withExtendedLifetime(mockRouter) {}
        withExtendedLifetime(subscriptionDisposeBag) {}
    }

    @Test("a late report of an older interface does not end the loading of a newer one")
    func aLateReportOfAnOlderInterfaceDoesNotEndLoading() async throws {
        let interfaceDisplayedRelay = PublishRelay<ContentInterface.ID>()
        let appDefaults = AppDefaults.isolated()
        let (viewModel, mockRouter) = makeViewModel(
            runtimeObject: makeRuntimeObject(),
            appDefaults: appDefaults,
            interfaceProvider: { runtimeObject, _ in
                RuntimeObjectInterface(object: runtimeObject, interfaceString: "class ContentPipelineFixture {}")
            }
        )
        _ = viewModel.transform(Self.input(reportingDisplayedWith: interfaceDisplayedRelay))
        let loadingRecorder = LoadingStateRecorder()
        let subscriptionDisposeBag = DisposeBag()
        viewModel._commonLoading.asDriver()
            .driveOnNext { isLoading in
                loadingRecorder.record(isLoading)
            }
            .disposed(by: subscriptionDisposeBag)

        let firstPrepared = try await pollUntil(timeout: .seconds(10)) {
            viewModel.interface != nil
        }
        #expect(firstPrepared, "the first interface never reached the view model")
        let firstInterface = try #require(viewModel.interface)

        // A generation-option change prepares the same object anew. The store is the view model's own.
        appDefaults.options.swiftInterfaceOptions.printFieldOffset.toggle()
        let secondPrepared = try await pollUntil(timeout: .seconds(10)) {
            viewModel.interface.map { $0.id != firstInterface.id } ?? false
        }
        #expect(secondPrepared, "the options change never prepared a second interface")
        let secondInterface = try #require(viewModel.interface)

        interfaceDisplayedRelay.accept(firstInterface.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(loadingRecorder.isLoading, "a report of the first interface ended the loading of the second")

        interfaceDisplayedRelay.accept(secondInterface.id)
        let ended = try await pollUntil(timeout: .seconds(5)) {
            !loadingRecorder.isLoading
        }
        #expect(ended, "the report of the second interface did not end the loading")

        withExtendedLifetime(mockRouter) {}
        withExtendedLifetime(subscriptionDisposeBag) {}
    }

    private static func input(reportingDisplayedWith interfaceDisplayedRelay: PublishRelay<ContentInterface.ID>) -> ContentTextViewModel.Input {
        ContentTextViewModel.Input(
            runtimeObjectClicked: .empty(),
            runtimeObjectOpenedInNewTab: .empty(),
            interfaceDisplayed: interfaceDisplayedRelay.asSignal()
        )
    }

    // MARK: - Fetch errors must not kill the pipeline

    @Test("a failed fetch keeps the pipeline alive for subsequent changes")
    func failedFetchKeepsPipelineAlive() async throws {
        let fetchRecorder = InterfaceFetchRecorder(failingFirstFetches: 1)
        let fixtureRuntimeObject = makeRuntimeObject()
        let appDefaults = AppDefaults.isolated()
        let (viewModel, mockRouter) = makeViewModel(
            runtimeObject: fixtureRuntimeObject,
            appDefaults: appDefaults,
            interfaceProvider: { runtimeObject, _ in
                if fetchRecorder.recordFetch() {
                    throw StubInterfaceFetchError()
                }
                return RuntimeObjectInterface(object: runtimeObject, interfaceString: "class ContentPipelineFixture {}")
            }
        )

        let firstFetchCompleted = try await pollUntil(timeout: .seconds(10)) {
            fetchRecorder.fetchCount == 1
        }
        #expect(firstFetchCompleted, "initial fetch never ran")
        #expect(viewModel.interface == nil)

        // Re-trigger the fetch half via a generation-option change; before
        // the split this subscription was already dead (`catchAndReturn` on
        // the outer chain completed it on the first error). The store is the
        // view model's own, so no other test hears the change.
        appDefaults.options.swiftInterfaceOptions.printFieldOffset.toggle()

        let recovered = try await pollUntil(timeout: .seconds(10)) {
            viewModel.interface != nil
        }
        #expect(recovered, "an options change after a failed fetch never recovered the pipeline")
        #expect(fetchRecorder.fetchCount == 2)

        withExtendedLifetime(mockRouter) {}
    }

    // MARK: - Navigation revisits render from the interface cache

    @Test("recreating the view model for the same object renders from the cache without a new fetch")
    func navigationRevisitRendersFromCache() async throws {
        // The interface cache listens for `.fullReload` broadcasts on the
        // shared local engine; a concurrent suite broadcasting one (the
        // real-engine flush test) would flush this cache between the two
        // view models and turn the "no second fetch" assertion flaky.
        // Hold the cross-suite lock (see SharedLocalEngineTestLock.swift).
        try await withSharedLocalEngineLock {
            try await runNavigationRevisitRendersFromCache()
        }
    }

    private func runNavigationRevisitRendersFromCache() async throws {
        let fetchRecorder = InterfaceFetchRecorder()
        let fixtureRuntimeObject = makeRuntimeObject()
        let documentState = withLiveDependencyContext { DocumentState() }
        // One shared cache fed by a counting fetcher, with both view models
        // routed through it — the same shape `ContentCoordinator` produces
        // when navigation rebinds `ContentTextViewModel` onto one document.
        let interfaceCache = RuntimeInterfaceCache(documentState: documentState) { runtimeObject, _ in
            _ = fetchRecorder.recordFetch()
            return RuntimeObjectInterface(object: runtimeObject, interfaceString: "class ContentPipelineFixture {}")
        }
        let cacheProvider: ContentTextViewModel.InterfaceProvider = { runtimeObject, options in
            try await interfaceCache.interface(for: runtimeObject, options: options)
        }

        let firstMockRouter = MockRouter<ContentRoute>()
        var firstViewModel: ContentTextViewModel? = withLiveDependencyContext {
            ContentTextViewModel(
                runtimeObject: fixtureRuntimeObject,
                documentState: documentState,
                router: firstMockRouter,
                interfaceProvider: cacheProvider
            )
        }
        let firstRendered = try await pollUntil(timeout: .seconds(10)) {
            firstViewModel?.interface != nil
        }
        #expect(firstRendered, "the first view model never rendered")
        #expect(fetchRecorder.fetchCount == 1)

        // Navigate away: the coordinator drops the old view model…
        firstViewModel = nil

        // …and navigating back binds a fresh one for the same object.
        let secondMockRouter = MockRouter<ContentRoute>()
        let secondViewModel = withLiveDependencyContext {
            ContentTextViewModel(
                runtimeObject: fixtureRuntimeObject,
                documentState: documentState,
                router: secondMockRouter,
                interfaceProvider: cacheProvider
            )
        }
        let secondRendered = try await pollUntil(timeout: .seconds(10)) {
            secondViewModel.interface != nil
        }
        #expect(secondRendered, "the revisiting view model never rendered")
        #expect(fetchRecorder.fetchCount == 1, "a navigation revisit must render from the cache, not refetch")

        withExtendedLifetime(firstMockRouter) {}
        withExtendedLifetime(secondMockRouter) {}
    }

    // MARK: - A finished batch of the type index refetches

    /// The serving process's SDK type index finishes a batch and the engine
    /// broadcasts `.typeNamesResolved`: the engine dropped what it printed
    /// with `__C.` names, so the pane fetches its object again (proposal
    /// `swift-type-indexing-package` in MachOSwiftSection).
    @Test("a finished batch of the type index refetches the interface on screen")
    func typeNamesResolvedRefetchesTheInterface() async throws {
        // The broadcast goes out on the shared local engine, whose other
        // listeners (another suite's interface cache) it would disturb.
        try await withSharedLocalEngineLock {
            try await runTypeNamesResolvedRefetchesTheInterface()
        }
    }

    private func runTypeNamesResolvedRefetchesTheInterface() async throws {
        let fetchRecorder = InterfaceFetchRecorder()
        let documentState = withLiveDependencyContext { DocumentState() }
        let mockRouter = MockRouter<ContentRoute>()
        let viewModel = withLiveDependencyContext {
            ContentTextViewModel(
                runtimeObject: makeRuntimeObject(),
                documentState: documentState,
                router: mockRouter,
                interfaceProvider: { runtimeObject, _ in
                    _ = fetchRecorder.recordFetch()
                    return RuntimeObjectInterface(object: runtimeObject, interfaceString: "class ContentPipelineFixture {}")
                }
            )
        }
        let firstPrepared = try await pollUntil(timeout: .seconds(10)) {
            viewModel.interface != nil
        }
        #expect(firstPrepared, "the interface never reached the view model")
        let firstInterface = try #require(viewModel.interface)
        #expect(fetchRecorder.fetchCount == 1)

        documentState.runtimeEngine.dataChangeSubject.send(.typeNamesResolved(platformName: "macosx"))
        let refetched = try await pollUntil(timeout: .seconds(10)) {
            viewModel.interface.map { $0.id != firstInterface.id } ?? false
        }
        #expect(refetched, "the broadcast did not refetch the interface")
        #expect(fetchRecorder.fetchCount == 2)

        // Another kind of change leaves the pane alone.
        documentState.runtimeEngine.dataChangeSubject.send(.fullReload(isReloadImageNodes: false))
        try await Task.sleep(for: .milliseconds(300))
        #expect(fetchRecorder.fetchCount == 2)

        withExtendedLifetime(mockRouter) {}
    }

    // MARK: - An interface Print Exported Declarations Only empties

    /// The engine prints an object that Print Exported Declarations Only
    /// leaves nothing of as empty — batch export skips it on that — and the
    /// pane says why in its place. The option that counts is the one of the
    /// side of Generation Options printing the object; anything else empty
    /// stays empty.
    @Test("only an empty interface whose side has Print Exported Declarations Only on is replaced by a note")
    func onlyAnEmptiedInterfaceIsReplaced() {
        let swiftObject = makeRuntimeObject()
        let objcClass = RuntimeObject(name: "ContentPipelineFixture", displayName: "ContentPipelineFixture", kind: .objc(.type(.class)), imagePath: swiftObject.imagePath, children: [])
        let objcCategory = RuntimeObject(name: "ContentPipelineFixture(Additions)", displayName: "ContentPipelineFixture(Additions)", kind: .objc(.category(.class)), imagePath: swiftObject.imagePath, children: [])
        let cStruct = RuntimeObject(name: "ContentPipelineStruct", displayName: "ContentPipelineStruct", kind: .c(.struct), imagePath: swiftObject.imagePath, children: [])
        var swiftExportedOnlyOptions = RuntimeObjectInterface.GenerationOptions()
        swiftExportedOnlyOptions.swiftInterfaceOptions.printExportedDeclarationsOnly = true
        var objcExportedOnlyOptions = RuntimeObjectInterface.GenerationOptions()
        objcExportedOnlyOptions.objcHeaderOptions.printExportedDeclarationsOnly = true

        let note = ContentTextViewModel.displayedInterfaceString(of: RuntimeObjectInterface(object: swiftObject, interfaceString: ""), options: swiftExportedOnlyOptions).string
        #expect(note.contains("TestFramework.ContentPipelineFixture prints nothing while Print Exported Declarations Only is on."), "\(note)")
        #expect(note.contains("show what TestFramework does not export"), "\(note)")
        for objcObject in [objcClass, objcCategory] {
            let objcNote = ContentTextViewModel.displayedInterfaceString(of: RuntimeObjectInterface(object: objcObject, interfaceString: ""), options: objcExportedOnlyOptions).string
            #expect(objcNote.contains("\(objcObject.displayName) prints nothing while Print Exported Declarations Only is on."), "\(objcNote)")
        }

        let emptyWithTheOptionsOff = ContentTextViewModel.displayedInterfaceString(of: RuntimeObjectInterface(object: swiftObject, interfaceString: ""), options: RuntimeObjectInterface.GenerationOptions())
        let swiftUnderTheObjectiveCOption = ContentTextViewModel.displayedInterfaceString(of: RuntimeObjectInterface(object: swiftObject, interfaceString: ""), options: objcExportedOnlyOptions)
        let objectiveCUnderTheSwiftOption = ContentTextViewModel.displayedInterfaceString(of: RuntimeObjectInterface(object: objcClass, interfaceString: ""), options: swiftExportedOnlyOptions)
        let emptyCStruct = ContentTextViewModel.displayedInterfaceString(of: RuntimeObjectInterface(object: cStruct, interfaceString: ""), options: objcExportedOnlyOptions)
        let printed = ContentTextViewModel.displayedInterfaceString(of: RuntimeObjectInterface(object: swiftObject, interfaceString: "class ContentPipelineFixture {}"), options: swiftExportedOnlyOptions)
        #expect(emptyWithTheOptionsOff.isEmpty)
        #expect(swiftUnderTheObjectiveCOption.isEmpty)
        #expect(objectiveCUnderTheSwiftOption.isEmpty)
        #expect(emptyCStruct.isEmpty)
        #expect(printed.string == "class ContentPipelineFixture {}")
    }

    /// A peer that predates Generated Interface ignores the language and answers with the header,
    /// without saying in which language: the pane says why rather than show a header as Swift.
    @Test("a Generated Interface answered in the object's own language says the peer predates it")
    func olderPeerAnswersWithTheHeader() {
        let objcClass = Fixtures.runtimeObject(name: "NSColor", kind: .objc(.type(.class)))
        var swiftOptions = RuntimeObjectInterface.GenerationOptions()
        swiftOptions.interfaceLanguage = .swift
        let header = RuntimeObjectInterface(object: objcClass, interfaceString: "@interface NSColor : NSObject")

        let note = ContentTextViewModel.displayedInterfaceString(of: header, options: swiftOptions).string
        #expect(note.contains("earlier RuntimeViewer"), "\(note)")
        #expect(!note.contains("@interface"), "\(note)")
        #expect(ContentTextViewModel.displayedInterface(of: header, runtimeObject: objcClass, options: swiftOptions).commentStructure?.comments.count == 2)

        // This build's peer answers in Swift and says so.
        let swiftForm = RuntimeObjectInterface(object: objcClass, interfaceString: "class NSColor: __C.NSObject {}", interfaceLanguage: .swift)
        #expect(ContentTextViewModel.displayedInterfaceString(of: swiftForm, options: swiftOptions).string == "class NSColor: __C.NSObject {}")
        // A request in the object's own language never shows the note.
        #expect(ContentTextViewModel.displayedInterfaceString(of: header, options: RuntimeObjectInterface.GenerationOptions()).string == "@interface NSColor : NSObject")
    }

    @Test("the pane shows the note for an interface fetched empty with the option on")
    func paneShowsTheNoteForAnEmptiedInterface() async throws {
        let appDefaults = AppDefaults.isolated()
        appDefaults.options.swiftInterfaceOptions.printExportedDeclarationsOnly = true
        let (viewModel, mockRouter) = makeViewModel(
            runtimeObject: makeRuntimeObject(),
            appDefaults: appDefaults,
            interfaceProvider: { runtimeObject, _ in
                RuntimeObjectInterface(object: runtimeObject, interfaceString: "")
            }
        )

        let rendered = try await pollUntil(timeout: .seconds(10)) {
            viewModel.interface?.string.contains("Print Exported Declarations Only") == true
        }
        #expect(rendered, "the note never reached the pane: \(viewModel.interface?.string ?? "nil")")
        withExtendedLifetime(mockRouter) {}
    }

    // MARK: - The live context keeps the app's own defaults out of reach

    /// The live context the pipeline needs resolves every key it does not
    /// override to its live value, and for `\.appDefaults` that is the app's
    /// own store: the bookmark files under `Application Support/AppStorage`
    /// and the standard defaults. The target-wide `withLiveDependencyContext`
    /// pins it to an isolated instance, but this suite's helper of the same
    /// name shadows that one, so it has to pin it as well.
    @Test("the suite's live dependency context resolves an isolated AppDefaults, not the app's own")
    func liveDependencyContextResolvesIsolatedAppDefaults() {
        let generationOptionsKey = "generationOptions"
        let standardOptionsBefore = UserDefaults.standard.data(forKey: generationOptionsKey)
        // Only a broken pin writes the standard defaults; put them back then,
        // so the failure does not leak into the next run.
        defer {
            if UserDefaults.standard.data(forKey: generationOptionsKey) != standardOptionsBefore {
                UserDefaults.standard.set(standardOptionsBefore, forKey: generationOptionsKey)
            }
        }

        let appDefaults = withLiveDependencyContext {
            @Dependency(\.appDefaults) var appDefaults
            return appDefaults
        }
        appDefaults.options.objcHeaderOptions.stripSynthesizedIvars.toggle()

        #expect(
            UserDefaults.standard.data(forKey: generationOptionsKey) == standardOptionsBefore,
            "the live context resolved the app's own AppDefaults, which writes the standard defaults"
        )
    }

    // MARK: - Fixtures

    private func makeViewModel(
        runtimeObject: RuntimeObject,
        appDefaults: AppDefaults = .isolated(),
        interfaceProvider: @escaping ContentTextViewModel.InterfaceProvider
    ) -> (viewModel: ContentTextViewModel, router: MockRouter<ContentRoute>) {
        withLiveDependencyContext(appDefaults: appDefaults) {
            let documentState = DocumentState()
            let mockRouter = MockRouter<ContentRoute>()
            let viewModel = ContentTextViewModel(
                runtimeObject: runtimeObject,
                documentState: documentState,
                router: mockRouter,
                interfaceProvider: interfaceProvider
            )
            return (viewModel, mockRouter)
        }
    }

    private func makeRuntimeObject() -> RuntimeObject {
        RuntimeObject(
            name: "TestFramework.ContentPipelineFixture",
            displayName: "TestFramework.ContentPipelineFixture",
            kind: .swift(.type(.class)),
            imagePath: "/System/Library/Frameworks/TestFramework.framework/TestFramework",
            children: [],
            properties: []
        )
    }

    /// Thread-safe fetch recorder for the injected `InterfaceProvider`
    /// (invoked on the pipeline's background fetch Task).
    private final class InterfaceFetchRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedFetchCount = 0
        private var storedFailuresRemaining: Int

        init(failingFirstFetches failureCount: Int = 0) {
            storedFailuresRemaining = failureCount
        }

        var fetchCount: Int {
            lock.withLock { storedFetchCount }
        }

        /// Records one fetch; returns whether this fetch should fail.
        func recordFetch() -> Bool {
            lock.withLock {
                storedFetchCount += 1
                guard storedFailuresRemaining > 0 else { return false }
                storedFailuresRemaining -= 1
                return true
            }
        }
    }

    // `Swift.Error` spelled out: an imported module also exports a type
    // named `Error`, which otherwise shadows the standard library protocol.
    private struct StubInterfaceFetchError: Swift.Error {}

    /// Thread-safe recorder of the latest `_commonLoading` state (delivered on
    /// the main thread by the driver, read from the polling loop).
    private final class LoadingStateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedIsLoading = false

        var isLoading: Bool {
            lock.withLock { storedIsLoading }
        }

        func record(_ isLoading: Bool) {
            lock.withLock { storedIsLoading = isLoading }
        }
    }

    // MARK: - Dependency helpers

    /// Forces the live dependency context: the pipeline resolves
    /// `\.settings` / `\.resolvedThemeStream` internally, and those entries
    /// declare no test value.
    ///
    /// `\.settings` is then overridden back to an in-memory store. The live
    /// context is what the other entries need, but for this one it resolves to
    /// the real settings file — see ``testSettings``. `\.appDefaults` is
    /// pinned to an isolated store for the same reason: its live value is the
    /// app's own, backed by the user's bookmark files and the standard
    /// defaults. This helper shadows the target-wide one of the same name,
    /// which pins `\.appDefaults` too, so it has to repeat that override.
    /// Keep both overrides here rather than at the call sites: every path into
    /// the pipeline goes through this helper, so one omission at a call site
    /// would quietly reconnect the real files.
    ///
    /// Pass `appDefaults` to share a store with the view model built inside,
    /// so a test can change the options that view model reads.
    private func withLiveDependencyContext<Result>(
        appDefaults: AppDefaults = .isolated(),
        _ operation: () throws -> Result
    ) rethrows -> Result {
        try withDependencies {
            $0.context = .live
            $0.settings = Self.testSettings
            $0.appDefaults = appDefaults
        } operation: {
            try operation()
        }
    }

    private func liveSettings() -> SettingsAccess {
        withLiveDependencyContext {
            @Dependency(\.settings) var settings
            return settings
        }
    }

    // MARK: - Polling helper

    private func pollUntil(
        timeout: Duration,
        _ condition: () async throws -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}
