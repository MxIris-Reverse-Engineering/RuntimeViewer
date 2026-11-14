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

    /// The language the pane asks for the interface in: `nil` for the object's own, `.swift` for
    /// an Objective-C object shown as Swift imports it (Generated Interface). Fixed for the
    /// ViewModel: another language is another navigation entry, which binds a new one.
    public let interfaceLanguage: RuntimeInterfaceLanguage?

    /// Whether the right-click menu offers Generated Interface: the object on screen has one.
    public var offersGeneratedInterface: Bool {
        runtimeObject.hasGeneratedInterface
    }

    /// Whether Generated Interface is the form on screen, which its menu item's check mark shows.
    public var showsGeneratedInterface: Bool {
        NavigationEntry(object: runtimeObject, interfaceLanguage: interfaceLanguage).showsGeneratedInterface
    }

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

        /// The attached macros this text shows folded, which the SourceEditor pane can expand in
        /// place; empty when the engine sent none. The `NSTextView` pane does not read them.
        public var macroExpansions: [MacroExpansion] = []
    }

    /// An attached macro of the rendered text — `@Observation.Observable` — with what it wrote,
    /// in the places it goes.
    public struct MacroExpansion: Sendable {
        /// The macro as its attribute names it, `Observation.Observable`.
        public let macroName: String

        /// Where the attribute is in the rendered text, in UTF-16 offsets, as the editor indexes it.
        /// For an expansion in a part's `nestedExpansions`, where it is in that part's `content`.
        public let attributeCharacterRange: NSRange

        /// What the macro wrote, a part for each place it goes, in text order.
        public let parts: [Part]

        /// One place of the expansion: what it hangs at in the rendered text, on which side of
        /// that line, and the declarations, without indentation of their own.
        public struct Part: Sendable {
            /// A tracked property's declaration, or the line of the type's closing brace, in
            /// UTF-16 offsets of the rendered text.
            public let anchorCharacterRange: NSRange

            public let placement: RuntimeInterfaceMacroExpansion.Part.Placement

            public let content: FrozenSemanticString

            /// The macros `content` attaches — `@ObservationTracked` — each expandable from inside
            /// the shown part, with its parts hanging in the rendered text.
            public let nestedExpansions: [MacroExpansion]
        }
    }

    /// What the fetch half hands the render half: the text to show, the object it belongs to, and
    /// the structure of its comments and the macro expansions when the engine sent them.
    struct FetchedInterface: Sendable {
        let interfaceString: FrozenSemanticString
        let runtimeObject: RuntimeObject
        let commentStructure: RuntimeInterfaceCommentStructure?
        var macroExpansions: [RuntimeInterfaceMacroExpansion] = []
    }

    @RxObserved
    public private(set) var renderedInterface: RenderedInterface?

    @RxObserved
    public private(set) var attributedString: NSAttributedString?

    /// The range the `ContentHighlightRequest` this ViewModel was built with
    /// resolved to in the text on screen — the Find navigator's hit, once the
    /// interface is rendered.
    private let highlightRangeRelay = PublishRelay<NSRange>()

    /// The search the `ContentHighlightRequest` came from, for the pane's find
    /// bar, when the request asks for it.
    private let findBarQueryRelay = PublishRelay<ContentFindBarQuery>()

    /// Whether this ViewModel was built to reveal a Find navigator hit, which
    /// its first render is followed by.
    private let highlightsFirstRender: Bool

    /// The Find navigator hit this ViewModel was built to show, until its first render uses it.
    /// Owned here, not by the document, so it goes away with the navigation that brought it: a
    /// navigation that moves on, an interface that cannot be fetched or an engine switch drops
    /// the ViewModel and the request with it.
    private var pendingHighlightRequest: ContentHighlightRequest?

    /// The editor pane this content is shown in. A link opened here opens from this pane, which
    /// takes the focus first, and the insertion point is reported as this pane's.
    private let editorPaneID: EditorPane.ID

    /// - Parameters:
    ///   - highlightRequest: where the Find navigator's hit sits, to reveal once the interface is
    ///     first on screen; `nil` for every other way of showing an object.
    ///   - editorPaneID: the editor pane showing the content; the focused pane when `nil`, which
    ///     is right wherever the editor area has a single pane.
    public convenience init(runtimeObject: RuntimeObject, interfaceLanguage: RuntimeInterfaceLanguage? = nil, highlightRequest: ContentHighlightRequest? = nil, editorPaneID: EditorPane.ID? = nil, documentState: DocumentState, router: any Router<ContentRoute>) {
        self.init(runtimeObject: runtimeObject, interfaceLanguage: interfaceLanguage, highlightRequest: highlightRequest, editorPaneID: editorPaneID, documentState: documentState, router: router, interfaceProvider: nil)
    }

    init(
        runtimeObject: RuntimeObject,
        interfaceLanguage: RuntimeInterfaceLanguage? = nil,
        highlightRequest: ContentHighlightRequest? = nil,
        editorPaneID: EditorPane.ID? = nil,
        documentState: DocumentState,
        router: any Router<ContentRoute>,
        interfaceProvider: InterfaceProvider?
    ) {
        self.runtimeObject = runtimeObject
        self.interfaceLanguage = interfaceLanguage
        self.pendingHighlightRequest = highlightRequest
        self.highlightsFirstRender = highlightRequest != nil
        self.editorPaneID = editorPaneID ?? documentState.editorArea.focusedPaneID
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
                runtimeEngine: { await documentState?.runtimeEngine },
                // Indexing the object's image is the user's own load, which the Report's Manual
                // Loading records (proposal `editor-jump-bar`).
                indexingImage: { imagePath, runtimeEngine in
                    if let documentState {
                        try await documentState.indexImageForUser(at: imagePath)
                    } else {
                        try await runtimeEngine.indexImageIfNeeded(at: imagePath)
                    }
                }
            )
        }
        super.init(documentState: documentState, router: router)

        self.imageNameOfRuntimeObject = runtimeObject.imageName

        let resolvedInterfaceProvider = self.interfaceProvider

        let transformerObservable: Observable<Transformer.Configuration>
        let marksCommentStructureObservable: Observable<Bool>
        // Fixed for the process: whether SourceEditor runs does not change while the app does.
        // Merged the way `currentMergedGenerationOptions` merges it, like the comment structure.
        let marksAttachedMacros: Bool
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        marksAttachedMacros = settings.editor.showsMacroExpansionsInline
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
        marksAttachedMacros = false
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
                mergedOptions.marksAttachedMacros = marksAttachedMacros
                mergedOptions.interfaceLanguage = interfaceLanguage
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
        //
        // The find bar's query goes first, with or without a range: opening the
        // bar selects a match of its own, which the reveal then replaces.
        $renderedInterface
            .compactMap { $0 }
            .flatMapLatest { [weak self] rendered -> Observable<(ContentHighlightRequest, NSRange?)> in
                guard let self, let request = self.pendingHighlightRequest else { return .empty() }
                self.pendingHighlightRequest = nil
                let displayedText = rendered.attributedString.string
                return Observable.just(())
                    .observe(on: renderScheduler)
                    .map { (request, request.locate(in: displayedText)) }
            }
            .observeOnMainScheduler()
            .subscribeOnNext { [weak self] request, range in
                guard let self else { return }
                if let findBarQuery = request.findBarQuery {
                    findBarQueryRelay.accept(findBarQuery)
                }
                if let range {
                    highlightRangeRelay.accept(range)
                }
            }
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
        runtimeEngine: () async -> RuntimeEngine?,
        indexingImage indexImage: (_ imagePath: String, _ runtimeEngine: RuntimeEngine) async throws -> Void = { imagePath, runtimeEngine in
            try await runtimeEngine.indexImageIfNeeded(at: imagePath)
        }
    ) async throws -> RuntimeObjectInterface? {
        if let interface = try await fetchInterface() {
            return interface
        }
        guard !runtimeObject.imagePath.isEmpty, let runtimeEngine = await runtimeEngine() else { return nil }
        try await indexImage(runtimeObject.imagePath, runtimeEngine)
        return try await fetchInterface()
    }

    /// The interface the pane shows for a fetched one: the same, except an object that Print
    /// Exported Declarations Only leaves empty — a Swift type or an Objective-C class its image
    /// does not export, or a category on such a class, reached through a link or listed while the
    /// sidebar does not exclude it — which says why instead of showing nothing. The engine itself
    /// prints such an object as empty, which is what batch export skips. The option is the one of
    /// the side of Generation Options that prints the object; C structs and unions it never
    /// empties.
    nonisolated static func displayedInterfaceString(
        of interface: RuntimeObjectInterface,
        options: RuntimeObjectInterface.GenerationOptions
    ) -> FrozenSemanticString {
        if isAnsweredInAnotherLanguage(interface, options: options) {
            // The peer predates Generated Interface: it ignored the language and sent the header.
            return SemanticString {
                Comment("\(interface.object.displayName) cannot be shown as Swift imports it: this engine's process runs an earlier RuntimeViewer, which sends only the Objective-C header.")
                BreakLine()
                Comment("Go back to see the header.")
            }
            .frozen()
        }
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

    /// Whether the interface was asked for in a language and came back in another: from a peer that
    /// predates `GenerationOptions.interfaceLanguage`, which ignores it and answers in the object's
    /// own language without saying which.
    nonisolated static func isAnsweredInAnotherLanguage(
        _ interface: RuntimeObjectInterface,
        options: RuntimeObjectInterface.GenerationOptions
    ) -> Bool {
        guard let requestedLanguage = options.interfaceLanguage else { return false }
        return interface.interfaceLanguage != requestedLanguage
    }

    /// Whether Print Exported Declarations Only left the interface empty, on the side of Generation
    /// Options that prints the object.
    private nonisolated static func showsExportedOnlyNote(
        for interface: RuntimeObjectInterface,
        options: RuntimeObjectInterface.GenerationOptions
    ) -> Bool {
        let kind = interface.object.kind
        let printsExportedDeclarationsOnly = kind.isSwift
            ? options.swiftInterfaceOptions.printExportedDeclarationsOnly
            : kind.isObjC && options.objcHeaderOptions.printExportedDeclarationsOnly
        return interface.interfaceString.isEmpty && printsExportedDeclarationsOnly
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
        let showsNote = isAnsweredInAnotherLanguage(interface, options: options) || showsExportedOnlyNote(for: interface, options: options)
        let commentStructure = showsNote
            ? noteCommentStructure(of: interfaceString)
            : interface.commentStructure
        // A note shifts the text the attributes' offsets were taken in, and stands for a text with
        // no macro to expand anyway.
        return FetchedInterface(
            interfaceString: interfaceString,
            runtimeObject: runtimeObject,
            commentStructure: commentStructure,
            macroExpansions: showsNote ? [] : interface.macroExpansions ?? []
        )
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
            commentDecorations: commentDecorations,
            macroExpansions: renderedMacroExpansions(of: fetchedInterface)
        )
    }

    /// The fetched interface's macro expansions, their attributes and the anchors of their parts
    /// located in UTF-16 offsets of its text. A part whose anchor's UTF-8 range does not fall on
    /// character boundaries of that text is left out, and so is an expansion whose attribute does
    /// not or that has no part left. A nested expansion's attribute is located the same way in
    /// the text of the part that holds it.
    nonisolated static func renderedMacroExpansions(of fetchedInterface: FetchedInterface) -> [MacroExpansion] {
        guard !fetchedInterface.macroExpansions.isEmpty else { return [] }
        let text = fetchedInterface.interfaceString.string
        return fetchedInterface.macroExpansions.compactMap { expansion in
            renderedMacroExpansion(expansion, attributeIn: text, anchorsIn: text)
        }
    }

    private nonisolated static func renderedMacroExpansion(
        _ expansion: RuntimeInterfaceMacroExpansion,
        attributeIn attributeText: String,
        anchorsIn text: String
    ) -> MacroExpansion? {
        guard let attributeCharacterRange = characterRange(ofUTF8Range: expansion.attributeUTF8Range, in: attributeText) else { return nil }
        let parts = expansion.parts.compactMap { part -> MacroExpansion.Part? in
            guard let anchorCharacterRange = characterRange(ofUTF8Range: part.anchorUTF8Range, in: text) else { return nil }
            let partText = part.content.string
            return MacroExpansion.Part(
                anchorCharacterRange: anchorCharacterRange,
                placement: part.placement,
                content: part.content,
                nestedExpansions: part.nestedExpansions.compactMap { nestedExpansion in
                    renderedMacroExpansion(nestedExpansion, attributeIn: partText, anchorsIn: text)
                }
            )
        }
        guard !parts.isEmpty else { return nil }
        return MacroExpansion(macroName: expansion.macroName, attributeCharacterRange: attributeCharacterRange, parts: parts)
    }

    /// `utf8Range` of `text` in UTF-16 offsets, or nil when it does not fall on character
    /// boundaries of `text`.
    private nonisolated static func characterRange(ofUTF8Range utf8Range: Range<Int>, in text: String) -> NSRange? {
        let utf8View = text.utf8
        guard utf8Range.lowerBound >= 0, utf8Range.upperBound <= utf8View.count,
              let lowerBound = utf8View.index(utf8View.startIndex, offsetBy: utf8Range.lowerBound).samePosition(in: text),
              let upperBound = utf8View.index(utf8View.startIndex, offsetBy: utf8Range.upperBound).samePosition(in: text)
        else { return nil }
        return NSRange(lowerBound ..< upperBound, in: text)
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
        /// ⌘-click on a type link / "Jump to Definition": opens the type in
        /// this pane's tab.
        public let runtimeObjectClicked: Signal<RuntimeObject>
        /// ⇧⌥⌘- or ⇧⌘-click on a type link / "Open in New Tab". Resolved the
        /// same way as `runtimeObjectClicked`, opened in a new tab of this pane.
        public let runtimeObjectOpenedInNewTab: Signal<RuntimeObject>
        /// ⌥⌘-click on a type link / "Open in Next Editor Pane". Resolved the
        /// same way, opened in the pane after this one.
        @Init(default: Signal<RuntimeObject>.empty())
        public let runtimeObjectOpenedInNextEditorPane: Signal<RuntimeObject>
        /// Find Call Hierarchy, Find Callees or Find Type References chosen in
        /// the right-click menu.
        @Init(default: Signal<FindCrossReferenceRequest>.empty())
        public let crossReferenceRequested: Signal<FindCrossReferenceRequest>
        /// The member declared on the insertion point's line as it moves, or
        /// `nil` off every member's line.
        @Init(default: Signal<RuntimeMemberReference?>.empty())
        public let cursorMemberChanged: Signal<RuntimeMemberReference?>
        /// Generated Interface chosen in the right-click menu: the object on screen as Swift
        /// imports it, or back in its own language, where the modifier keys say.
        @Init(default: Signal<SelectionRoute.Destination>.empty())
        public let generatedInterfaceToggled: Signal<SelectionRoute.Destination>
        /// A command every list offers on a runtime object, chosen in the
        /// right-click menu on a type link (Copy Name).
        @Init(default: Signal<RuntimeObjectActionRequest>.empty())
        public let runtimeObjectActionRequested: Signal<RuntimeObjectActionRequest>
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
        /// Show this query in the pane's find bar, every match marked: the
        /// search a Find navigator text hit came from. Emits at most once, just
        /// before `highlightRange` for the same hit.
        public let findBarQuery: Signal<ContentFindBarQuery>
        /// Whether the first `renderedInterface` is followed by a
        /// `highlightRange`. A pane that puts the reader back where they left an
        /// interface skips that for the first render, so the hit is what shows.
        public let highlightsFirstRender: Bool
    }

    public func transform(_ input: Input) -> Output {
        let runtimeObjectNotFoundRelay = PublishRelay<Void>()
        
        // Every link flow resolves through the shared `interfaceProvider`
        // with the same merged options the destination ContentTextViewModel
        // will fetch with, so the resolution fetch warms the cache entry the
        // display fetch then hits — one engine round-trip per link click
        // instead of two. Which object the engine resolves does not depend on
        // the options; they only shape the generated text. One pipeline for
        // the three destinations: a newer click supersedes a resolution still
        // under way, whichever way either was opened.
        let linkOpenings: Signal<(runtimeObject: RuntimeObject, destination: SelectionRoute.Destination)> = Signal.merge(
            input.runtimeObjectClicked.map { ($0, .focusedTab) },
            input.runtimeObjectOpenedInNewTab.map { ($0, .newTab) },
            input.runtimeObjectOpenedInNextEditorPane.map { ($0, .nextEditorPane) }
        )
        linkOpenings
            .flatMapLatest { [weak self] runtimeObject, destination -> Signal<(RuntimeObjectInterface?, SelectionRoute.Destination)> in
                guard let self else { return .empty() }
                let interfaceProvider = self.interfaceProvider
                let mergedOptions = self.currentMergedGenerationOptions
                return Observable.async {
                    try await interfaceProvider(runtimeObject, mergedOptions)
                }
                .trackActivity(self._commonLoading)
                .map { ($0, destination) }
                .asSignal(onErrorJustReturn: (nil, destination))
            }
            .emit(with: self) { target, resolution in
                let (interface, destination) = resolution
                guard let interface else {
                    runtimeObjectNotFoundRelay.accept(())
                    return
                }
                // Opened from this pane: it takes the focus first, so the
                // focused tab, the new tab and the next pane are all reckoned
                // from here, whichever pane had the focus before.
                target.documentState.selectionRouter.trigger(.focusEditorPane(target.editorPaneID))
                let interfaceLanguage = NavigationEntry.interfaceLanguage(forLinkTo: interface.object, from: target.interfaceLanguage)
                target.documentState.selectionRouter.trigger(.open(interface.object, in: destination, interfaceLanguage: interfaceLanguage))
            }
            .disposed(by: rx.disposeBag)

        input.generatedInterfaceToggled.emitOnNext { [weak self] destination in
            guard let self,
                  let toggledEntry = NavigationEntry(object: runtimeObject, interfaceLanguage: interfaceLanguage).togglingGeneratedInterface,
                  let toggledObject = toggledEntry.object
            else { return }
            documentState.selectionRouter.trigger(.focusEditorPane(editorPaneID))
            documentState.selectionRouter.trigger(.open(toggledObject, in: destination, interfaceLanguage: toggledEntry.interfaceLanguage))
        }
        .disposed(by: rx.disposeBag)

        input.crossReferenceRequested.emitOnNext { [weak self] request in
            guard let self else { return }
            documentState.findSession.runCrossReferenceCommand(request)
        }
        .disposed(by: rx.disposeBag)

        #if os(macOS)
        input.runtimeObjectActionRequested.emitOnNext { [weak self] request in
            guard let self else { return }
            perform(request.action, on: request.runtimeObject)
        }
        .disposed(by: rx.disposeBag)
        #endif

        // Only a member of the object on screen: a late event from the text of
        // the object before must not stand for this one.
        input.cursorMemberChanged.emitOnNext { [weak self] member in
            guard let self else { return }
            documentState.updateCursorMember(member?.object == runtimeObject ? member : nil, inEditorPane: editorPaneID)
        }
        .disposed(by: rx.disposeBag)

        return Output(
            renderedInterface: $renderedInterface.asDriver().compactMap { $0 },
            attributedString: $attributedString.asDriver().compactMap { $0 },
            theme: $theme.asDriver(),
            imageNameOfRuntimeObject: $imageNameOfRuntimeObject.asDriver(),
            selectedRuntimeObjectName: documentState.$selectedRuntimeObject.asDriver().map { $0?.displayName ?? "" },
            runtimeObjectNotFound: runtimeObjectNotFoundRelay.asSignal(),
            highlightRange: highlightRangeRelay.asSignal(),
            findBarQuery: findBarQueryRelay.asSignal(),
            highlightsFirstRender: highlightsFirstRender
        )
    }
}

extension NSAttributedString: @unchecked @retroactive Sendable {}

extension NSAttributedString.Key {
    /// The `RuntimeMemberReference` a line of the content pane's text declares,
    /// over the whole line; see `ContentTextViewModel.markingDeclaredMembers(in:of:)`.
    public static let runtimeViewerDeclaredMember = NSAttributedString.Key("RuntimeViewerDeclaredMember")
}
