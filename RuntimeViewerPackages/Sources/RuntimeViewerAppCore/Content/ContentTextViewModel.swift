#if canImport(AppKit) && !targetEnvironment(macCatalyst)
@preconcurrency import RuntimeViewerSettings
#endif

import Foundation
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
        /// The C-imported types the text declares under two names, and the spelling it was printed
        /// with, which decides what the SourceEditor pane offers beside each.
        var cImportedTypeNames: [RuntimeInterfaceCImportedTypeName] = []
        var cImportedTypeNameSpelling: SwiftGenerationOptions.CImportedTypeNameSpelling = .swiftName
    }

    /// The interface on screen: the text, the tables the pane looks things up in, and what the
    /// SourceEditor pane draws beside it. The view themes it (RuntimeViewerAppUI's
    /// `ContentTextRenderer`) and reports it displayed (`Input.interfaceDisplayed`).
    @RxObserved
    public private(set) var interface: ContentInterface?

    /// The views' reports that they put an interface on screen, which end its wait in the loading
    /// indicator.
    private let interfaceDisplayedRelay = PublishRelay<ContentInterface.ID>()

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
        // Merged the way `SettingsAccess.mergingRequestOptions(into:)` merges it, like the comment structure.
        let marksAttachedMacros: Bool
        let marksCImportedTypeNames: Bool
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        marksAttachedMacros = settings.editor.showsMacroExpansionsInline
        marksCImportedTypeNames = settings.editor.showsCImportedTypeNameTags
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
        // Merged the way `SettingsAccess.mergingRequestOptions(into:)` merges it, so a link
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
        marksCImportedTypeNames = false
        #endif

        // ── Fetch half ──────────────────────────────────────────────────
        // Only object / generation-option / transformer changes reach the
        // engine. The theme is not this view model's: a theme or font-size
        // change re-themes the interface on screen in the view's
        // `ContentTextRenderer` (RuntimeViewerAppUI), without a refetch.
        //
        // Capture the document-scoped dependencies instead of `self`: the
        // `Observable.async` Task keeps running briefly after disposal
        // (cancellation is cooperative), so an `unowned self` here aborts in
        // `swift_unknownObjectUnownedLoadStrong` whenever the ViewModel is
        // rebound away (tab switch / close) mid-generation.
        // A batch of the serving process's SDK type index finished: the engine
        // dropped its printed interfaces, so a refetch shows the names it
        // resolves now (`RuntimeDataChange.typeNamesResolved`; proposal
        // swift-type-indexing-package). The document's interface cache
        // flushes on the same broadcast, but on a schedule of its own: flush
        // it here too, on the main actor before the refetch reads it, so the
        // refetch never gets an interface printed before the batch. Counted,
        // so each batch is a new value.
        let typeNameResolutionCount = documentState.$runtimeEngineSession.asObservable()
            .flatMapLatest { session in session.engine.dataChangePublisher.asObservable() }
            .filter { change in
                if case .typeNamesResolved = change { true } else { false }
            }
            .observe(on: MainScheduler.instance)
            .do(onNext: { [interfaceCache] _ in
                MainActor.assumeIsolated {
                    interfaceCache.invalidateAll()
                }
            })
            .scan(0) { count, _ in count + 1 }
            .startWith(0)
        // The effective Generation Options of the image the object on screen is in (proposal
        // `generation-options-image-overrides`): a change to the global options or to this image's
        // override refetches, one to another image's override does not. Paired with the object it
        // was worked out for, so every object the pane is given still fetches once.
        let runtimeEngine = documentState.runtimeEngine
        let objectAndGenerationOptions = $runtimeObject
            .flatMapLatest { [settings] runtimeObject -> Observable<(RuntimeObject, RuntimeObjectInterface.GenerationOptions)> in
                settings.effectiveGenerationOptionsObservable(forImageAt: runtimeObject.imagePath, in: runtimeEngine)
                    .map { (runtimeObject, $0) }
            }
        let interfaceStream = Observable
            .combineLatest(
                objectAndGenerationOptions,
                transformerObservable.distinctUntilChanged(),
                marksCommentStructureObservable.distinctUntilChanged(),
                typeNameResolutionCount
            )
            .flatMapLatest { [_commonLoading = self._commonLoading] objectAndGenerationOptions, transformer, marksCommentStructure, _ -> Observable<FetchedInterface?> in
                let (runtimeObject, options) = objectAndGenerationOptions
                var mergedOptions = options
                mergedOptions.transformer = transformer
                mergedOptions.marksCommentStructure = marksCommentStructure
                mergedOptions.marksAttachedMacros = marksAttachedMacros
                mergedOptions.marksCImportedTypeNames = marksCImportedTypeNames
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

        // ── Prepare half (off-main) ─────────────────────────────────────
        // Builds the tables the pane looks things up in — links, declared
        // members — with the comment decorations and the macro expansions, on
        // a background scheduler; `flatMapLatest` drops a superseded build.
        //
        // One scheduler for the pipeline's lifetime: the convenience
        // initializer allocates a fresh DispatchQueue, so constructing it
        // inside the closure would churn a queue per emission.
        let prepareScheduler = ConcurrentDispatchQueueScheduler(qos: .userInitiated)
        interfaceStream
            .flatMapLatest { [_commonLoading = self._commonLoading, interfaceDisplayedRelay] fetchedInterface -> Observable<ContentInterface?> in
                guard let fetchedInterface else { return .just(nil) }
                let interfaceID = ContentInterface.ID()
                // Tracked from here until the view reports this interface on
                // screen, so the indicator covers click → new text on screen
                // with the view's theming inside it. The sequence emits the
                // interface, then stays open until the report: its
                // subscription to the reports is made as the interface is
                // emitted, before it reaches the main thread and the view.
                // A newer interface drops this wait (`flatMapLatest`), so a
                // late report of an older one ends nothing. No dark gap
                // between the halves either: the fetch's element propagates
                // here (incrementing the activity) before its
                // `Observable.async` completes and decrements.
                let displayed = interfaceDisplayedRelay
                    .filter { $0 == interfaceID }
                    .take(1)
                    .ignoreElements()
                    .asObservable()
                    .map { _ -> ContentInterface? in nil }
                return Observable.just(())
                    .observe(on: prepareScheduler)
                    .map { ContentInterface?.some(ContentInterface.prepared(from: fetchedInterface, id: interfaceID)) }
                    .concat(displayed)
                    .trackActivity(_commonLoading)
            }
            .observeOnMainScheduler()
            .bind(to: $interface)
            .disposed(by: rx.disposeBag)

        // A Find navigator hit arrives with the route that built this ViewModel;
        // once the object's text is first prepared, locate it in that text (off
        // main — the text can be megabytes) and hand the range to the view.
        // Used once: later interfaces (options) leave the scroll position alone.
        //
        // The find bar's query goes first, with or without a range: opening the
        // bar selects a match of its own, which the reveal then replaces.
        $interface
            .compactMap { $0 }
            .flatMapLatest { [weak self] interface -> Observable<(ContentHighlightRequest, NSRange?)> in
                guard let self, let request = self.pendingHighlightRequest else { return .empty() }
                self.pendingHighlightRequest = nil
                let displayedText = interface.string
                return Observable.just(())
                    .observe(on: prepareScheduler)
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

    /// Where the note sends the user to turn Print Exported Declarations Only off: the global
    /// options, and on the Mac the image's own sheet (proposal `generation-options-image-overrides`).
    nonisolated static var generationOptionsLocation: String {
        #if os(macOS)
        "Settings › Generation Options, or for this image under Editor › Generation Options,"
        #else
        "Settings › Generation Options"
        #endif
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
            Comment("Turn it off in \(generationOptionsLocation) to show what \(interface.object.imageName) does not export.")
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
            macroExpansions: showsNote ? [] : interface.macroExpansions ?? [],
            cImportedTypeNames: showsNote ? [] : interface.cImportedTypeNames ?? [],
            cImportedTypeNameSpelling: options.swiftInterfaceOptions.cImportedTypeNameSpelling
        )
    }

    /// The tag the SourceEditor pane shows after each C-imported type the fetched interface declares
    /// under two names (proposal `c-imported-type-name-spelling` in MachOSwiftSection): the name the
    /// text does not print, which a click switches to. A declared name whose UTF-8 range does not
    /// fall on character boundaries of the text is left out.
    nonisolated static func cImportedTypeNameTags(of fetchedInterface: FetchedInterface) -> [CImportedTypeNameTag] {
        guard !fetchedInterface.cImportedTypeNames.isEmpty else { return [] }
        let text = fetchedInterface.interfaceString.string
        return fetchedInterface.cImportedTypeNames.compactMap { names in
            guard let range = characterRange(ofUTF8Range: names.nameUTF8Range, in: text) else { return nil }
            switch fetchedInterface.cImportedTypeNameSpelling {
            case .swiftName:
                return CImportedTypeNameTag(range: range, label: "C name", name: names.cName, toolTip: "Show C Names")
            case .cName:
                return CImportedTypeNameTag(range: range, label: "Swift name", name: names.swiftName, toolTip: "Show Swift Names")
            }
        }
    }

    /// A tag after a C-imported type's declaration: its other name, which a click on the tag
    /// switches every pane to.
    public struct CImportedTypeNameTag: Sendable, Equatable {
        /// The declared name, in UTF-16 offsets of the text; the tag sits after the end of its line.
        public let range: NSRange
        /// Which name the tag holds: `C name`, `Swift name`.
        public let label: String
        /// The name the text does not print: `AGWeakAttribute`.
        public let name: String
        /// What a click does.
        public let toolTip: String
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

    @MemberwiseInit(.public)
    public struct Input {
        /// ⌘-click on a type link / "Jump to Definition": opens the type in
        /// this pane's tab.
        public let runtimeObjectClicked: Signal<RuntimeObject>
        /// ⇧⌥⌘- or ⇧⌘-click on a type link / "Open in New Tab". Resolved the
        /// same way as `runtimeObjectClicked`, opened in a new tab of this pane.
        public let runtimeObjectOpenedInNewTab: Signal<RuntimeObject>
        /// The view has put this interface on screen — themed and set, or handed to the editor —
        /// which ends the loading indicator's wait for it. No default: a pane that never reported
        /// would leave the indicator on for good.
        public let interfaceDisplayed: Signal<ContentInterface.ID>
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
        /// A C-imported type's tag clicked: every pane prints imported type names the other way
        /// (`SwiftGenerationOptions.cImportedTypeNameSpelling`).
        @Init(default: Signal<Void>.empty())
        public let cImportedTypeNameSpellingToggled: Signal<Void>
    }

    public struct Output {
        /// The interface to show, each a new one; the view themes it and reports it displayed.
        public let interface: Driver<ContentInterface>
        public let imageNameOfRuntimeObject: Driver<String?>
        /// The name of the object this pane shows — its own, not the document's selection: on iOS
        /// each page of the navigation stack is titled with it, and the back button shows the
        /// page below's.
        public let runtimeObjectName: Driver<String>
        public let runtimeObjectNotFound: Signal<Void>
        /// Scroll to and flash this range: a Find navigator hit located in the
        /// text on screen. Emits at most once per pending highlight.
        public let highlightRange: Signal<NSRange>
        /// Show this query in the pane's find bar, every match marked: the
        /// search a Find navigator text hit came from. Emits at most once, just
        /// before `highlightRange` for the same hit.
        public let findBarQuery: Signal<ContentFindBarQuery>
        /// Whether the first `interface` is followed by a
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
                // The destination object's image: its options are what the pane that shows it
                // fetches with.
                let mergedOptions = self.mergedGenerationOptions(for: runtimeObject)
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

        // The spelling is a Generation Option like any other, and the tag switches it for the image
        // the object is in: it is recorded as that image's override, which refetches every pane
        // showing an object of the image (proposal `generation-options-image-overrides`).
        input.cImportedTypeNameSpellingToggled.emitOnNext { [weak self] in
            guard let self else { return }
            settings.generationOptions.updateOverride(forImageAt: runtimeObject.imagePath, in: documentState.runtimeEngine) { options in
                options.swiftInterfaceOptions.cImportedTypeNameSpelling = options.swiftInterfaceOptions.cImportedTypeNameSpelling.toggled
            }
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

        input.interfaceDisplayed
            .emit(to: interfaceDisplayedRelay)
            .disposed(by: rx.disposeBag)

        return Output(
            interface: $interface.asDriver().compactMap { $0 },
            imageNameOfRuntimeObject: $imageNameOfRuntimeObject.asDriver(),
            runtimeObjectName: $runtimeObject.asDriver().map(\.displayName),
            runtimeObjectNotFound: runtimeObjectNotFoundRelay.asSignal(),
            highlightRange: highlightRangeRelay.asSignal(),
            findBarQuery: findBarQueryRelay.asSignal(),
            highlightsFirstRender: highlightsFirstRender
        )
    }
}
