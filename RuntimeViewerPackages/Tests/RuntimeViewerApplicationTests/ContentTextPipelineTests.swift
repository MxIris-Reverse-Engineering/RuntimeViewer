import AppKit
import Foundation
import Dependencies
import RxSwift
import RuntimeViewerCore
import RuntimeViewerSettings
import RuntimeViewerArchitectures
import Semantic
import Testing
@testable import RuntimeViewerApplication

/// Regression suite for the split content-text pipeline
/// (`ContentTextViewModel`'s fetch half vs. render half).
///
/// History: before the 2026-08 split, the interface fetch and the attributed
/// string build lived in a single `combineLatest` that also observed the
/// theme — so every theme / font-size change re-fetched the interface over
/// XPC and rebuilt the whole attributed string on the main thread, and a
/// trailing `catchAndReturn` on the outer chain completed the pipeline on
/// the first fetch error, permanently freezing the tab. The assertions
/// below pin all three fixes: theme-only changes must not re-fetch, a
/// failed fetch must not kill the pipeline, and the off-main render helper
/// must reproduce the direct builder output byte for byte.
@Suite("ContentTextPipeline", .serialized)
@MainActor
struct ContentTextPipelineTests {
    // MARK: - Theme-only changes must not re-fetch

    @Test("font-size change re-renders without re-fetching the interface")
    func fontSizeChangeDoesNotRefetch() async throws {
        let fetchRecorder = InterfaceFetchRecorder()
        let fixtureRuntimeObject = makeRuntimeObject()
        let (viewModel, mockRouter) = makeViewModel(
            runtimeObject: fixtureRuntimeObject,
            interfaceProvider: { runtimeObject, _ in
                _ = fetchRecorder.recordFetch()
                return RuntimeObjectInterface(object: runtimeObject, interfaceString: "class ContentPipelineFixture {}")
            }
        )

        let initialRendered = try await pollUntil(timeout: .seconds(10)) {
            viewModel.attributedString != nil
        }
        #expect(initialRendered, "initial fetch never produced an attributed string")
        #expect(fetchRecorder.fetchCount == 1)
        let initialAttributedString = try #require(viewModel.attributedString)

        let settings = liveSettings()
        let originalFontSize = settings.theme.fontSize
        defer { withLiveDependencyContext { settings.theme.fontSize = originalFontSize } }

        let changedFontSize = originalFontSize + 3
        withLiveDependencyContext { settings.theme.fontSize = changedFontSize }

        let rebuiltWithNewFontSize = try await pollUntil(timeout: .seconds(10)) {
            guard let rebuiltAttributedString = viewModel.attributedString,
                  rebuiltAttributedString !== initialAttributedString,
                  rebuiltAttributedString.length > 0,
                  let font = rebuiltAttributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            else { return false }
            return font.pointSize == CGFloat(changedFontSize)
        }
        #expect(rebuiltWithNewFontSize, "font-size change never produced a re-rendered attributed string")
        #expect(fetchRecorder.fetchCount == 1, "a theme-only change must not re-fetch the interface")

        // The view model holds its router unowned — keep the mock alive
        // until every assertion has run.
        withExtendedLifetime(mockRouter) {}
    }

    // MARK: - The loading indicator must cover the render half

    /// PR #88 review, finding 3: after the fetch/render split, only the
    /// fetch half was tracked by `_commonLoading` — a theme or font-size
    /// change re-renders without ever entering a tracked region, so the
    /// indicator never appears even though the user is waiting on the
    /// rebuild. This fails against a fetch-only `trackActivity` placement.
    @Test("font-size change surfaces the loading indicator through the render half")
    func fontSizeChangeSurfacesLoadingIndicator() async throws {
        let fixtureRuntimeObject = makeRuntimeObject()
        let (viewModel, mockRouter) = makeViewModel(
            runtimeObject: fixtureRuntimeObject,
            interfaceProvider: { runtimeObject, _ in
                RuntimeObjectInterface(object: runtimeObject, interfaceString: "class ContentPipelineFixture {}")
            }
        )

        let initialRendered = try await pollUntil(timeout: .seconds(10)) {
            viewModel.attributedString != nil
        }
        #expect(initialRendered, "initial fetch never produced an attributed string")
        let initialAttributedString = try #require(viewModel.attributedString)

        // Record loading emissions only from here on, so the initial
        // fetch's activity cannot satisfy the assertion.
        let loadingRecorder = LoadingEmissionRecorder()
        let subscriptionDisposeBag = DisposeBag()
        viewModel._commonLoading.asDriver()
            .driveOnNext { isLoading in
                loadingRecorder.record(isLoading)
            }
            .disposed(by: subscriptionDisposeBag)

        let settings = liveSettings()
        let originalFontSize = settings.theme.fontSize
        defer { withLiveDependencyContext { settings.theme.fontSize = originalFontSize } }
        withLiveDependencyContext { settings.theme.fontSize = originalFontSize + 3 }

        let rebuilt = try await pollUntil(timeout: .seconds(10)) {
            viewModel.attributedString !== initialAttributedString && viewModel.attributedString != nil
        }
        #expect(rebuilt, "font-size change never produced a re-rendered attributed string")
        let indicatorAppeared = try await pollUntil(timeout: .seconds(5)) {
            loadingRecorder.sawLoading
        }
        #expect(indicatorAppeared, "a theme-only re-render must pass through a tracked region so the indicator can appear")

        withExtendedLifetime(mockRouter) {}
        withExtendedLifetime(subscriptionDisposeBag) {}
    }

    // MARK: - Fetch errors must not kill the pipeline

    @Test("a failed fetch keeps the pipeline alive for subsequent changes")
    func failedFetchKeepsPipelineAlive() async throws {
        let fetchRecorder = InterfaceFetchRecorder(failingFirstFetches: 1)
        let fixtureRuntimeObject = makeRuntimeObject()
        let (viewModel, mockRouter) = makeViewModel(
            runtimeObject: fixtureRuntimeObject,
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
        #expect(viewModel.attributedString == nil)

        // Re-trigger the fetch half via a generation-option change; before
        // the split this subscription was already dead (`catchAndReturn` on
        // the outer chain completed it on the first error).
        let appDefaults = liveAppDefaults()
        let originalOptions = appDefaults.options
        defer { appDefaults.options = originalOptions }
        appDefaults.options.swiftInterfaceOptions.printFieldOffset.toggle()

        let recovered = try await pollUntil(timeout: .seconds(10)) {
            viewModel.attributedString != nil
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
            firstViewModel?.attributedString != nil
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
            secondViewModel.attributedString != nil
        }
        #expect(secondRendered, "the revisiting view model never rendered")
        #expect(fetchRecorder.fetchCount == 1, "a navigation revisit must render from the cache, not refetch")

        withExtendedLifetime(firstMockRouter) {}
        withExtendedLifetime(secondMockRouter) {}
    }

    // MARK: - Render helper equivalence (pins the PR2 restyle baseline)

    @Test("renderAttributedString matches a direct builder invocation and returns an immutable string")
    func renderMatchesDirectBuilderInvocation() {
        let fixtureRuntimeObject = makeRuntimeObject()
        let interfaceString: SemanticString = "class ContentPipelineFixture {}"
        let theme = ResolvedTheme.fallback

        let rendered = ContentTextViewModel.renderAttributedString(
            for: (interfaceString: interfaceString, runtimeObject: fixtureRuntimeObject),
            theme: theme
        )
        let direct = interfaceString.attributedString(for: theme, runtimeObjectName: fixtureRuntimeObject)
        #expect(rendered?.isEqual(to: direct) == true)

        // The cross-thread handoff contract: the builder must not leak its
        // mutable working copy.
        #expect(!(rendered is NSMutableAttributedString))
        #expect(ContentTextViewModel.renderAttributedString(for: nil, theme: theme) == nil)
    }

    // MARK: - Fixtures

    private func makeViewModel(
        runtimeObject: RuntimeObject,
        interfaceProvider: @escaping ContentTextViewModel.InterfaceProvider
    ) -> (viewModel: ContentTextViewModel, router: MockRouter<ContentRoute>) {
        withLiveDependencyContext {
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
            secondaryKind: nil,
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

    /// Thread-safe recorder for `_commonLoading` emissions (delivered on
    /// the main thread by the driver, read from the polling loop).
    private final class LoadingEmissionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedSawLoading = false

        var sawLoading: Bool {
            lock.withLock { storedSawLoading }
        }

        func record(_ isLoading: Bool) {
            guard isLoading else { return }
            lock.withLock { storedSawLoading = true }
        }
    }

    // MARK: - Dependency helpers

    /// Forces the live dependency context: the pipeline resolves
    /// `\.settings` / `\.resolvedThemeStream` internally, and those entries
    /// declare no test value.
    private func withLiveDependencyContext<Result>(_ operation: () throws -> Result) rethrows -> Result {
        try withDependencies {
            $0.context = .live
        } operation: {
            try operation()
        }
    }

    private func liveSettings() -> Settings {
        withLiveDependencyContext {
            @Dependency(\.settings) var settings
            return settings
        }
    }

    private func liveAppDefaults() -> AppDefaults {
        withLiveDependencyContext {
            @Dependency(\.appDefaults) var appDefaults
            return appDefaults
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
