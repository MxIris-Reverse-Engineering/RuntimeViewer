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
import RuntimeViewerCrossReferences
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
    /// itself on engine swaps and data-change events. It first waits out
    /// the delay Settings › Developer may set; an injected provider does not.
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
        public let semanticString: FrozenSemanticString

        /// The same content with the theme's colors and fonts applied, plus the `.link`
        /// attributes that carry jump targets and the `.runtimeViewerDeclaredMember` attributes
        /// that say which member a line declares.
        public let attributedString: NSAttributedString

        /// How the SourceEditor pane draws the comments of this text; nil when the engine sent no
        /// comment structure with it. The `NSTextView` pane does not read it.
        public let commentDecorations: InterfaceCommentDecorations?
    }

    /// What the fetch half hands the render half: the text to show, the object it belongs to, and
    /// the structure of its comments when the engine sent one.
    struct FetchedInterface: Sendable {
        let interfaceString: FrozenSemanticString
        let runtimeObject: RuntimeObject
        let commentStructure: RuntimeInterfaceCommentStructure?
    }

    @RxObserved
    public private(set) var renderedInterface: RenderedInterface?

    @RxObserved
    public private(set) var attributedString: NSAttributedString?

    /// The range the `ContentHighlightRequest` this ViewModel was built with
    /// resolved to in the text on screen — the Find navigator's hit, once the
    /// interface is rendered.
    private let highlightRangeRelay = PublishRelay<NSRange>()

    /// The Find navigator hit this ViewModel was built to show, until its first render uses it.
    /// Owned here, not by the document, so it goes away with the navigation that brought it: a
    /// navigation that moves on, an interface that cannot be fetched or an engine switch drops
    /// the ViewModel and the request with it.
    private var pendingHighlightRequest: ContentHighlightRequest?

    /// - Parameter highlightRequest: where the Find navigator's hit sits, to reveal once the
    ///   interface is first on screen; `nil` for every other way of showing an object.
    public convenience init(runtimeObject: RuntimeObject, highlightRequest: ContentHighlightRequest? = nil, documentState: DocumentState, router: any Router<ContentRoute>) {
        self.init(runtimeObject: runtimeObject, highlightRequest: highlightRequest, documentState: documentState, router: router, interfaceProvider: nil)
    }

    init(
        runtimeObject: RuntimeObject,
        highlightRequest: ContentHighlightRequest? = nil,
        documentState: DocumentState,
        router: any Router<ContentRoute>,
        interfaceProvider: InterfaceProvider?
    ) {
        self.runtimeObject = runtimeObject
        self.pendingHighlightRequest = highlightRequest
        self.theme = ResolvedTheme.fallback
        let interfaceCache = documentState.interfaceCache
        let contentLoadingDelay = Self.contentLoadingDelay()
        self.interfaceProvider = interfaceProvider ?? { [interfaceCache, weak documentState] runtimeObject, options in
            if contentLoadingDelay > 0 {
                try await Task.sleep(for: .seconds(contentLoadingDelay))
            }
            return try await ContentTextViewModel.interface(
                of: runtimeObject,
                fetchingWith: { try await interfaceCache.interface(for: runtimeObject, options: options) },
                runtimeEngine: { await documentState?.runtimeEngine }
            )
        }
        super.init(documentState: documentState, router: router)

        self.imageNameOfRuntimeObject = runtimeObject.imageName

        let resolvedInterfaceProvider = self.interfaceProvider

        let transformerObservable: Observable<Transformer.Configuration>
        let marksCommentStructureObservable: Observable<Bool>
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
        // Merged the way `currentMergedGenerationOptions` merges it, so a link
        // click warms the cache entry this fetch then hits.
        marksCommentStructureObservable = Observable<Bool>
            .tracking {
                MainActor.assumeIsolated {
                    trackedSettings.editor.drawsCommentTags
                }
            }
            .share(replay: 1, scope: .whileConnected)
        #else
        transformerObservable = .just(.init())
        marksCommentStructureObservable = .just(false)
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
                transformerObservable.distinctUntilChanged(),
                marksCommentStructureObservable.distinctUntilChanged()
            )
            .flatMapLatest { [_commonLoading = self._commonLoading] runtimeObject, options, transformer, marksCommentStructure -> Observable<FetchedInterface?> in
                var mergedOptions = options
                mergedOptions.transformer = transformer
                mergedOptions.marksCommentStructure = marksCommentStructure
                return Observable.async {
                    let fetchInterval = contentTextSignposter.beginInterval("content.interfaceFetch", id: contentTextSignposter.makeSignpostID())
                    defer { contentTextSignposter.endInterval("content.interfaceFetch", fetchInterval) }
                    return try await resolvedInterfaceProvider(runtimeObject, mergedOptions).map {
                        Self.displayedInterface(of: $0, runtimeObject: runtimeObject, options: mergedOptions)
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
            .flatMapLatest { [_commonLoading = self._commonLoading] fetchedInterface, theme -> Observable<RenderedInterface?> in
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
                    .map { Self.renderInterface(for: fetchedInterface, theme: theme) }
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

        // A Find navigator hit arrives with the route that built this ViewModel;
        // once the object's text is first rendered, locate it in that text (off
        // main — the text can be megabytes) and hand the range to the view.
        // Used once: later renders (theme, options) leave the scroll position alone.
        $renderedInterface
            .compactMap { $0 }
            .flatMapLatest { [weak self] rendered -> Observable<NSRange?> in
                guard let self, let request = self.pendingHighlightRequest else { return .empty() }
                self.pendingHighlightRequest = nil
                let displayedText = rendered.attributedString.string
                return Observable.just(())
                    .observe(on: renderScheduler)
                    .map { request.locate(in: displayedText) }
            }
            .observeOnMainScheduler()
            .compactMap { $0 }
            .bind(to: highlightRangeRelay)
            .disposed(by: rx.disposeBag)
    }

    /// The wait Settings › Developer puts ahead of every fetch; zero while its master switch is
    /// off, and wherever that page does not exist.
    ///
    /// Read once per ViewModel rather than per fetch: the fetch runs off the main actor, where
    /// settings cannot be read, and the pane builds a new ViewModel for every object it shows,
    /// so a changed delay still applies from the next selection on.
    private static func contentLoadingDelay() -> TimeInterval {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        @Dependency(\.settings) var settings
        return settings.developer.effectiveContentLoadingDelay
        #else
        return 0
        #endif
    }

    /// The interface `fetchInterface` gives for `runtimeObject`, or — when it gives none — the one
    /// it gives once the object's image is indexed. A Find hit can be in an image whose sections are
    /// not built: its corpus came from derived data (proposal `derived-data`). The image is
    /// indexed the way the sidebar opens one — joining a background build of it under way — and the
    /// interface asked for again, all under the pane's loading overlay; a load that fails is a fetch
    /// that failed. `runtimeEngine` is asked only then.
    ///
    /// The interface is asked for again even when the image turns out to be indexed already:
    /// background indexing can finish it between the first ask and the check, and the pane does
    /// not ask again by itself — it would stay blank until the user navigates away and back.
    nonisolated static func interface(
        of runtimeObject: RuntimeObject,
        fetchingWith fetchInterface: () async throws -> RuntimeObjectInterface?,
        runtimeEngine: () async -> RuntimeEngine?
    ) async throws -> RuntimeObjectInterface? {
        if let interface = try await fetchInterface() {
            return interface
        }
        guard !runtimeObject.imagePath.isEmpty, let runtimeEngine = await runtimeEngine() else { return nil }
        try await runtimeEngine.indexImageIfNeeded(at: runtimeObject.imagePath)
        return try await fetchInterface()
    }

    /// The interface the pane shows for a fetched one: the same, except a Swift object that Print
    /// Exported Declarations Only leaves empty — a type its image does not export, reached through
    /// a link or listed while the sidebar does not exclude it — which says why instead of showing
    /// nothing. The engine itself prints such an object as empty, which is what batch export
    /// skips.
    nonisolated static func displayedInterfaceString(
        of interface: RuntimeObjectInterface,
        options: RuntimeObjectInterface.GenerationOptions
    ) -> FrozenSemanticString {
        guard showsExportedOnlyNote(for: interface, options: options) else { return interface.interfaceString }
        // Says what the option did, not that nothing here is exported: a type
        // the image does not export is left out whole, an exported type nested
        // in it included.
        return SemanticString {
            Comment("\(interface.object.displayName) prints nothing while Print Exported Declarations Only is on.")
            BreakLine()
            Comment("Turn it off in Generation Options to show what \(interface.object.imageName) does not export.")
        }
        .frozen()
    }

    private nonisolated static func showsExportedOnlyNote(
        for interface: RuntimeObjectInterface,
        options: RuntimeObjectInterface.GenerationOptions
    ) -> Bool {
        interface.interfaceString.isEmpty
            && interface.object.kind.isSwift
            && options.swiftInterfaceOptions.printExportedDeclarationsOnly
    }

    /// What the pane shows for a fetched interface, with the structure of its comments: the
    /// engine's, or — for the note `displayedInterfaceString(of:options:)` puts in place of an
    /// empty interface — one written here, so that the note is drawn like every other comment.
    nonisolated static func displayedInterface(
        of interface: RuntimeObjectInterface,
        runtimeObject: RuntimeObject,
        options: RuntimeObjectInterface.GenerationOptions
    ) -> FetchedInterface {
        let interfaceString = displayedInterfaceString(of: interface, options: options)
        let commentStructure = showsExportedOnlyNote(for: interface, options: options)
            ? noteCommentStructure(of: interfaceString)
            : interface.commentStructure
        return FetchedInterface(interfaceString: interfaceString, runtimeObject: runtimeObject, commentStructure: commentStructure)
    }

    /// Each `// ` line of `text` as a note: the marker, then the prose.
    private nonisolated static func noteCommentStructure(of text: FrozenSemanticString) -> RuntimeInterfaceCommentStructure {
        var comments: [RuntimeInterfaceCommentStructure.Comment] = []
        var segments: [RuntimeInterfaceCommentStructure.Segment] = []
        var lineStart = 0
        for line in text.string.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineLength = line.utf8.count
            defer { lineStart += lineLength + 1 }
            guard line.hasPrefix("// "), lineLength > 3 else { continue }
            let commentIndex = comments.count
            comments.append(.init(kind: .note, utf8Range: lineStart ..< lineStart + lineLength, enclosingCommentIndex: nil))
            segments.append(.init(role: .marker, utf8Range: lineStart ..< lineStart + 3, commentIndex: commentIndex))
            segments.append(.init(role: .text, utf8Range: lineStart + 3 ..< lineStart + lineLength, commentIndex: commentIndex))
        }
        return RuntimeInterfaceCommentStructure(comments: comments, segments: segments)
    }

    /// Builds both forms of a fetched interface in one pass, so the semantic runs and the
    /// attributed text a consumer receives always describe the same generation.
    ///
    /// `nonisolated` for the same reason as ``renderAttributedString(for:theme:)``, which it
    /// delegates the theming pass to: this runs on the render half's background scheduler.
    nonisolated static func renderInterface(
        for fetchedInterface: FetchedInterface?,
        theme: ThemeProfile
    ) -> RenderedInterface? {
        guard let fetchedInterface else { return nil }
        let interfacePair = (interfaceString: fetchedInterface.interfaceString, runtimeObject: fetchedInterface.runtimeObject)
        guard let attributedString = renderAttributedString(for: interfacePair, theme: theme) else { return nil }
        let commentDecorations = fetchedInterface.commentStructure.map {
            InterfaceCommentDecorations(structure: $0, interfaceString: fetchedInterface.interfaceString)
        }
        return RenderedInterface(
            semanticString: interfacePair.interfaceString,
            attributedString: markingDeclaredMembers(in: attributedString, of: interfacePair),
            commentDecorations: commentDecorations
        )
    }

    /// `attributedString` with every line that declares a member with code
    /// carrying it as `.runtimeViewerDeclaredMember`, which the right-click
    /// menu and the insertion point read off a character as the `.link`
    /// attribute names a type. Which line declares what is read the way the
    /// Find corpus locates members on their lines.
    nonisolated static func markingDeclaredMembers(
        in attributedString: NSAttributedString,
        of interfacePair: (interfaceString: FrozenSemanticString, runtimeObject: RuntimeObject)
    ) -> NSAttributedString {
        let interface = RuntimeObjectInterface(object: interfacePair.runtimeObject, interfaceString: interfacePair.interfaceString)
        let membersByLineNumber = interface.declaredMembersByLineNumber()
            .filter { FindCrossReferenceRoot.memberKindsWithCode.contains($0.value.kind) }
        guard !membersByLineNumber.isEmpty else { return attributedString }
        let markedString = NSMutableAttributedString(attributedString: attributedString)
        let text = attributedString.string as NSString
        var lineNumber = 1
        var lineStart = 0
        while lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            if let declaredMember = membersByLineNumber[lineNumber] {
                let member = RuntimeMemberReference(object: interfacePair.runtimeObject, name: declaredMember.name, kind: declaredMember.kind, isStatic: declaredMember.isStatic)
                markedString.addAttribute(.runtimeViewerDeclaredMember, value: member, range: lineRange)
            }
            lineNumber += 1
            lineStart = NSMaxRange(lineRange)
        }
        return markedString
    }

    /// Builds the display-ready attributed string for a fetched interface.
    ///
    /// `nonisolated`: invoked on the render half's background scheduler.
    /// Safe off the main thread — `ResolvedTheme`'s color/font lookups are
    /// init-time-precomputed read-only tables, and the builder allocates
    /// only immutable font/color/string values, returning an immutable copy.
    nonisolated static func renderAttributedString(
        for interfacePair: (interfaceString: FrozenSemanticString, runtimeObject: RuntimeObject)?,
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
        /// Find Call Hierarchy, Find Callees or Find Type References chosen in
        /// the right-click menu.
        @Init(default: Signal<FindCrossReferenceRequest>.empty())
        public let crossReferenceRequested: Signal<FindCrossReferenceRequest>
        /// The member declared on the insertion point's line as it moves, or
        /// `nil` off every member's line.
        @Init(default: Signal<RuntimeMemberReference?>.empty())
        public let cursorMemberChanged: Signal<RuntimeMemberReference?>
    }

    public struct Output {
        public let renderedInterface: Driver<RenderedInterface>
        public let attributedString: Driver<NSAttributedString>
        public let theme: Driver<ThemeProfile>
        public let imageNameOfRuntimeObject: Driver<String?>
        public let selectedRuntimeObjectName: Driver<String>
        public let runtimeObjectNotFound: Signal<Void>
        /// Scroll to and flash this range: a Find navigator hit located in the
        /// text on screen. Emits at most once per pending highlight.
        public let highlightRange: Signal<NSRange>
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

        input.crossReferenceRequested.emitOnNext { [weak self] request in
            guard let self else { return }
            documentState.findSession.runCrossReferenceCommand(request)
        }
        .disposed(by: rx.disposeBag)

        // Only a member of the object on screen: a late event from the text of
        // the object before must not stand for this one.
        input.cursorMemberChanged.emitOnNext { [weak self] member in
            guard let self else { return }
            documentState.updateCursorMember(member?.object == runtimeObject ? member : nil)
        }
        .disposed(by: rx.disposeBag)

        return Output(
            renderedInterface: $renderedInterface.asDriver().compactMap { $0 },
            attributedString: $attributedString.asDriver().compactMap { $0 },
            theme: $theme.asDriver(),
            imageNameOfRuntimeObject: $imageNameOfRuntimeObject.asDriver(),
            selectedRuntimeObjectName: documentState.$selectedRuntimeObject.asDriver().map { $0?.displayName ?? "" },
            runtimeObjectNotFound: runtimeObjectNotFoundRelay.asSignal(),
            highlightRange: highlightRangeRelay.asSignal()
        )
    }
}

extension NSAttributedString: @unchecked @retroactive Sendable {}

extension NSAttributedString.Key {
    /// The `RuntimeMemberReference` a line of the content pane's text declares,
    /// over the whole line; see `ContentTextViewModel.markingDeclaredMembers(in:of:)`.
    public static let runtimeViewerDeclaredMember = NSAttributedString.Key("RuntimeViewerDeclaredMember")
}
