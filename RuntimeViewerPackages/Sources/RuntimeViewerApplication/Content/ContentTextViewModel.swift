#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
@preconcurrency import RuntimeViewerSettings
#endif

#if canImport(UIKit)
import UIKit
#endif

import os
import Semantic
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit
import Dependencies

/// Signpost intervals for the two content-pipeline phases so Instruments
/// (Logging template) can attribute fetch vs. build wall time. Mirrors the
/// TypePicker precedent (`Specialization.TypePicker`).
private let contentTextSignposter = OSSignposter(
    subsystem: "com.RuntimeViewer.RuntimeViewerApplication",
    category: "Content.TextPipeline"
)

public final class ContentTextViewModel: ViewModel<ContentRoute> {
    /// Fetches the theme-independent interface of a runtime object.
    /// Injectable so tests can count fetches and simulate failures; the
    /// default implementation routes through the document's
    /// `RuntimeInterfaceCache`, which reads the current runtime engine at
    /// call time (the engine can be swapped mid-document) and flushes
    /// itself on engine swaps and data-change events.
    typealias InterfaceProvider = @Sendable (RuntimeObject, RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface?

    /// Single fetch path shared by the content pipeline's fetch half and
    /// the link-resolution flows in `transform(_:)`, so an injected test
    /// provider observes every fetch this ViewModel performs.
    private let interfaceProvider: InterfaceProvider

    @RxObserved
    public private(set) var theme: ThemeProfile

    @RxObserved
    public private(set) var runtimeObject: RuntimeObject

    @RxObserved
    public private(set) var imageNameOfRuntimeObject: String?

    /// The rendered interface, carrying both forms of the same generation.
    ///
    /// They travel together rather than as two `@RxObserved` properties because a consumer that
    /// needs both must never see one updated ahead of the other — the semantic runs would
    /// describe a different object than the text on screen.
    public struct RenderedInterface {
        /// Semantic runs from the generator: what each identifier actually *is*, which no
        /// amount of scanning the rendered text can recover.
        public let semanticString: SemanticString

        /// The same content with the theme's colors and fonts applied, plus the `.link`
        /// attributes that carry jump targets.
        public let attributedString: NSAttributedString
    }

    @RxObserved
    public private(set) var renderedInterface: RenderedInterface?

    @RxObserved
    public private(set) var attributedString: NSAttributedString?

    public convenience init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<ContentRoute>) {
        self.init(runtimeObject: runtimeObject, documentState: documentState, router: router, interfaceProvider: nil)
    }

    init(
        runtimeObject: RuntimeObject,
        documentState: DocumentState,
        router: any Router<ContentRoute>,
        interfaceProvider: InterfaceProvider?
    ) {
        self.runtimeObject = runtimeObject
        self.theme = ResolvedTheme.fallback
        let interfaceCache = documentState.interfaceCache
        self.interfaceProvider = interfaceProvider ?? { [interfaceCache] runtimeObject, options in
            try await interfaceCache.interface(for: runtimeObject, options: options)
        }
        super.init(documentState: documentState, router: router)

        self.imageNameOfRuntimeObject = runtimeObject.imageName

        let resolvedInterfaceProvider = self.interfaceProvider

        let transformerObservable: Observable<Transformer.Configuration>
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // Resolve the dependency once. `Observable.tracking` re-arms on a
        // main-queue hop where the dependency context is no longer available.
        // This is `ViewModel`'s own `settings`, already resolved by `super.init`
        // above — declaring a second local one here would only shadow it.
        let trackedSettings = settings
        transformerObservable = Observable<Transformer.Configuration>
            .tracking {
                // Main-actor isolated state read from `tracking`'s synchronous
                // first access — see the matching note in `ResolvedThemeStream`.
                MainActor.assumeIsolated {
                    trackedSettings.transformer
                }
            }
            .share(replay: 1, scope: .whileConnected)
        #else
        transformerObservable = .just(.init())
        #endif

        let themeObservable: Observable<ThemeProfile>
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // The shared stream multicasts a single `Observable.tracking` chain
        // across every document, so editing any custom preset only rebuilds
        // `ResolvedTheme` once instead of once per open document. Equatable
        // dedup happens upstream so the downstream `combineLatest` only
        // re-runs the engine `interface(for:)` fetch on a real change.
        @Dependency(\.resolvedThemeStream) var resolvedThemeStream
        themeObservable = resolvedThemeStream.observable.map { $0 as ThemeProfile }
        #else
        themeObservable = .just(ResolvedTheme.fallback)
        #endif

        themeObservable
            .observeOnMainScheduler()
            .bind(to: $theme)
            .disposed(by: rx.disposeBag)

        // ── Fetch half (theme-independent) ──────────────────────────────
        // Only object / generation-option / transformer changes reach the
        // engine; theme and font-size changes never trigger an XPC
        // round-trip — they replay the latest fetched interface into the
        // render half below.
        //
        // Capture the document-scoped dependencies instead of `self`: the
        // `Observable.async` Task keeps running briefly after disposal
        // (cancellation is cooperative), so an `unowned self` here aborts in
        // `swift_unknownObjectUnownedLoadStrong` whenever the ViewModel is
        // rebound away (tab switch / close) mid-generation.
        let interfaceStream = Observable
            .combineLatest(
                $runtimeObject,
                appDefaults.$options.distinctUntilChanged(),
                transformerObservable.distinctUntilChanged()
            )
            .flatMapLatest { [_commonLoading = self._commonLoading] runtimeObject, options, transformer -> Observable<(interfaceString: SemanticString, runtimeObject: RuntimeObject)?> in
                var mergedOptions = options
                mergedOptions.transformer = transformer
                return Observable.async {
                    let fetchInterval = contentTextSignposter.beginInterval("content.interfaceFetch", id: contentTextSignposter.makeSignpostID())
                    defer { contentTextSignposter.endInterval("content.interfaceFetch", fetchInterval) }
                    return try await resolvedInterfaceProvider(runtimeObject, mergedOptions).map {
                        (interfaceString: $0.interfaceString, runtimeObject: runtimeObject)
                    }
                }
                .trackActivity(_commonLoading)
                // The catch must live on this inner sequence: one failed
                // fetch surfaces as a single nil emission while the outer
                // subscription stays alive for subsequent object / options /
                // theme changes. A trailing `catchAndReturn` on the outer
                // chain would complete the whole pipeline on first error and
                // permanently freeze this tab's content.
                .catchAndReturn(nil)
            }
            .share(replay: 1, scope: .whileConnected)

        // ── Render half (theme-dependent, off-main) ─────────────────────
        // Rebuilds the attributed string whenever the fetched interface or
        // the theme changes. The build runs on a background scheduler;
        // `flatMapLatest` drops a superseded build's emission, so a burst of
        // font-size clicks only publishes the newest result.
        //
        // One scheduler for the pipeline's lifetime: the convenience
        // initializer allocates a fresh DispatchQueue, so constructing it
        // inside the closure would churn a queue per emission.
        let renderScheduler = ConcurrentDispatchQueueScheduler(qos: .userInitiated)
        Observable
            .combineLatest(interfaceStream, themeObservable)
            .flatMapLatest { [_commonLoading = self._commonLoading] interfacePair, theme -> Observable<RenderedInterface?> in
                // Tracked so the indicator covers click → new text on
                // screen: with a warm interface cache the fetch half is
                // near-instant, and theme / font-size changes skip it
                // entirely — without this, every visible wait would fall in
                // an untracked gap. No dark gap between the halves either:
                // the fetch's element propagates here (incrementing the
                // activity) before its `Observable.async` completes and
                // decrements.
                Observable.just(())
                    .observe(on: renderScheduler)
                    .map { Self.renderInterface(for: interfacePair, theme: theme) }
                    .trackActivity(_commonLoading)
            }
            .observeOnMainScheduler()
            .bind(to: $renderedInterface)
            .disposed(by: rx.disposeBag)

        // Kept as its own property so existing consumers are untouched; it is strictly derived.
        $renderedInterface
            .map { $0?.attributedString }
            .bind(to: $attributedString)
            .disposed(by: rx.disposeBag)
    }

    /// Builds both forms of a fetched interface in one pass, so the semantic runs and the
    /// attributed text a consumer receives always describe the same generation.
    ///
    /// `nonisolated` for the same reason as ``renderAttributedString(for:theme:)``, which it
    /// delegates the theming pass to: this runs on the render half's background scheduler.
    nonisolated static func renderInterface(
        for interfacePair: (interfaceString: SemanticString, runtimeObject: RuntimeObject)?,
        theme: ThemeProfile
    ) -> RenderedInterface? {
        guard let interfacePair,
              let attributedString = renderAttributedString(for: interfacePair, theme: theme)
        else { return nil }
        return RenderedInterface(
            semanticString: interfacePair.interfaceString,
            attributedString: attributedString
        )
    }

    /// Builds the display-ready attributed string for a fetched interface.
    ///
    /// `nonisolated`: invoked on the render half's background scheduler.
    /// Safe off the main thread — `ResolvedTheme`'s color/font lookups are
    /// init-time-precomputed read-only tables, and the builder allocates
    /// only immutable font/color/string values, returning an immutable copy.
    nonisolated static func renderAttributedString(
        for interfacePair: (interfaceString: SemanticString, runtimeObject: RuntimeObject)?,
        theme: ThemeProfile
    ) -> NSAttributedString? {
        guard let interfacePair else { return nil }
        let buildInterval = contentTextSignposter.beginInterval("content.attributedStringBuild", id: contentTextSignposter.makeSignpostID())
        defer { contentTextSignposter.endInterval("content.attributedStringBuild", buildInterval) }
        return interfacePair.interfaceString.attributedString(for: theme, runtimeObjectName: interfacePair.runtimeObject)
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let runtimeObjectClicked: Signal<RuntimeObject>
        /// ⌘⇧-click on a type link / "Open in New Tab" context menu item.
        /// Resolved the same way as `runtimeObjectClicked` but routed to
        /// `.openInNewTab` instead of an in-place `.push`.
        public let runtimeObjectOpenedInNewTab: Signal<RuntimeObject>
    }

    public struct Output {
        public let renderedInterface: Driver<RenderedInterface>
        public let attributedString: Driver<NSAttributedString>
        public let theme: Driver<ThemeProfile>
        public let imageNameOfRuntimeObject: Driver<String?>
        public let selectedRuntimeObjectName: Driver<String>
        public let runtimeObjectNotFound: Signal<Void>
    }

    public func transform(_ input: Input) -> Output {
        let runtimeObjectNotFoundRelay = PublishRelay<Void>()
        
        // Both link flows resolve through the shared `interfaceProvider`
        // with the same merged options the destination ContentTextViewModel
        // will fetch with, so the resolution fetch warms the cache entry the
        // post-push display fetch then hits — one engine round-trip per link
        // click instead of two. Which object the engine resolves does not
        // depend on the options; they only shape the generated text.
        input.runtimeObjectClicked
            .flatMapLatest { [weak self] runtimeObject -> Signal<RuntimeObjectInterface?> in
                guard let self else { return .empty() }
                let interfaceProvider = self.interfaceProvider
                let mergedOptions = self.currentMergedGenerationOptions
                return Observable.async {
                    try await interfaceProvider(runtimeObject, mergedOptions)
                }
                .trackActivity(self._commonLoading)
                .asSignal(onErrorJustReturn: nil)
            }
            .emit(with: self) { target, interface in
                if let interface {
                    target.documentState.selectionRouter.trigger(.push(interface.object))
                } else {
                    runtimeObjectNotFoundRelay.accept(())
                }
            }
            .disposed(by: rx.disposeBag)

        input.runtimeObjectOpenedInNewTab
            .flatMapLatest { [weak self] runtimeObject -> Signal<RuntimeObjectInterface?> in
                guard let self else { return .empty() }
                let interfaceProvider = self.interfaceProvider
                let mergedOptions = self.currentMergedGenerationOptions
                return Observable.async {
                    try await interfaceProvider(runtimeObject, mergedOptions)
                }
                .trackActivity(self._commonLoading)
                .asSignal(onErrorJustReturn: nil)
            }
            .emit(with: self) { target, interface in
                if let interface {
                    target.documentState.selectionRouter.trigger(.openInNewTab(interface.object))
                } else {
                    runtimeObjectNotFoundRelay.accept(())
                }
            }
            .disposed(by: rx.disposeBag)

        return Output(
            renderedInterface: $renderedInterface.asDriver().compactMap { $0 },
            attributedString: $attributedString.asDriver().compactMap { $0 },
            theme: $theme.asDriver(),
            imageNameOfRuntimeObject: $imageNameOfRuntimeObject.asDriver(),
            selectedRuntimeObjectName: documentState.$selectedRuntimeObject.asDriver().map { $0?.displayName ?? "" },
            runtimeObjectNotFound: runtimeObjectNotFoundRelay.asSignal()
        )
    }
}

extension NSAttributedString: @unchecked @retroactive Sendable {}
