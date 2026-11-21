#if os(macOS)

import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerArchitectures

/// The naming word cloud of one image of a document (proposal `naming-word-cloud`).
///
/// Types come from the image's object list, which needs no corpus: the type
/// measures are counted as soon as the image is indexed. Members come from
/// the image's Find corpus, asked of the engine with `members(in:shownUnder:)`;
/// when it is not built, the build is requested of the corpus coordinator the
/// document shares with every window on the engine, so it is the same build
/// Find would run, shown in the Report navigator and kept out of App Nap.
///
/// Members are listed as the document's Generation Options show them, with
/// synthesized accessors and ivars always hidden — otherwise a property would
/// be counted again as its getter, its setter and its ivar. New options, a
/// new engine or a corpus built again read everything again; a change of
/// measure within types or within members, of a switch or of the word limit
/// only counts again, off the main thread.
public final class NamingWordCloudViewModel: ViewModel<NamingWordCloudRoute> {
    public struct Input {
        public let preferenceChanged: Signal<NamingWordCloudPreferenceChange>
        /// A word chosen in the cloud or the ranking, by its key.
        public let wordSelected: Signal<String?>
        /// A row of the usage list, by its index.
        public let usageClicked: Signal<Int>
        public let retry: Signal<Void>
        public let exportRequested: Signal<NamingWordCloudExportFormat>
        public let compoundWordsRequested: Signal<Void>
        /// A click on a column header of the ranking.
        public let rankingColumnClicked: Signal<NamingWordRankingOrder.Column>

        public init(
            preferenceChanged: Signal<NamingWordCloudPreferenceChange>,
            wordSelected: Signal<String?>,
            usageClicked: Signal<Int>,
            retry: Signal<Void>,
            exportRequested: Signal<NamingWordCloudExportFormat>,
            compoundWordsRequested: Signal<Void>,
            rankingColumnClicked: Signal<NamingWordRankingOrder.Column> = .empty()
        ) {
            self.preferenceChanged = preferenceChanged
            self.wordSelected = wordSelected
            self.usageClicked = usageClicked
            self.retry = retry
            self.exportRequested = exportRequested
            self.compoundWordsRequested = compoundWordsRequested
            self.rankingColumnClicked = rankingColumnClicked
        }
    }

    public struct Output {
        public let state: Driver<NamingWordCloudState>
        public let preferences: Driver<NamingWordCloudPreferences>
        public let selectedWordKey: Driver<String?>
        /// "Manager — 128 types", or "No Word Selected".
        public let usageTitle: Driver<String>
        public let usageRows: Driver<[NamingWordCloudUsageRow]>
        /// Every word counted, in `rankingOrder`.
        public let rankingRows: Driver<[NamingWordCloudWord]>
        public let rankingOrder: Driver<NamingWordRankingOrder>
        /// "631 words" beside the ranking's title; empty while nothing is counted.
        public let wordCountText: Driver<String>
        /// "Kind" or "Declared In", as the measure lists names.
        public let usageDetailColumnTitle: Driver<String>
    }

    /// The image whose names the cloud counts.
    public let imagePath: String

    public var imageName: String {
        URL(fileURLWithPath: imagePath).deletingPathExtension().lastPathComponent
    }

    public var windowTitle: String {
        "Naming Word Cloud"
    }

    /// The image the window is about, under its title.
    public var windowSubtitle: String {
        imageName
    }

    /// What the usage list's title says while no word is selected.
    public static let noWordSelectedTitle = "No Word Selected"

    @RxObserved
    public private(set) var state: NamingWordCloudState = .indexingImage(fractionCompleted: nil)

    @RxObserved
    public private(set) var preferences: NamingWordCloudPreferences = NamingWordCloudPreferences()

    @RxObserved
    public private(set) var selectedWordKey: String?

    @RxObserved
    private(set) var usageTitle: String = NamingWordCloudViewModel.noWordSelectedTitle

    @RxObserved
    private(set) var usageRows: [NamingWordCloudUsageRow] = []

    @RxObserved
    private(set) var rankingOrder: NamingWordRankingOrder = .mostCommonFirst

    @RxObserved
    private(set) var rankingRows: [NamingWordCloudWord] = []

    /// The image's names as last read, and the prefix found in its type names.
    private struct Source {
        let types: [RuntimeObject]
        /// `nil` when the measure read no members.
        let members: [RuntimeObjectMembers]?
        let typePrefix: String?
    }

    private enum SourceEvent {
        case progress(NamingWordCloudState)
        case loaded(Source)
        case unavailable(NamingWordCloudUnavailability)
        case failed(String)
    }

    private struct UnavailableError: Error {
        let reason: NamingWordCloudUnavailability
    }

    private struct LoadingError: LocalizedError {
        let errorDescription: String?
    }

    private var source: Source?

    private var orderedWordCounts: [NamingWordCount] = []

    private var wordCountsByKey: [String: NamingWordCount] = [:]

    /// The prefix the last count took off type names.
    private var removedTypePrefix: String?

    private var recountTask: Task<Void, Never>?

    /// Reads the image's names again: Retry, or its corpus built again.
    private let reloadRelay = PublishRelay<Void>()

    private let corpusBuiltSubscription = SerialDisposable()

    public init(imagePath: String, documentState: DocumentState, router: any Router<NamingWordCloudRoute>) {
        self.imagePath = imagePath
        super.init(documentState: documentState, router: router)
        preferences = appDefaults.namingWordCloudPreferences
        setupPipelines()
    }

    // MARK: - Transform

    public func transform(_ input: Input) -> Output {
        input.preferenceChanged.emitOnNextMainActor { [weak self] change in
            guard let self else { return }
            var updatedPreferences = preferences
            change.apply(to: &updatedPreferences)
            guard updatedPreferences != preferences else { return }
            appDefaults.namingWordCloudPreferences = updatedPreferences
            adopt(updatedPreferences)
        }
        .disposed(by: rx.disposeBag)

        input.wordSelected.emitOnNextMainActor { [weak self] key in
            guard let self else { return }
            selectedWordKey = key.flatMap { self.wordCountsByKey[$0] == nil ? nil : $0 }
            updateUsages()
        }
        .disposed(by: rx.disposeBag)

        input.usageClicked.emitOnNextMainActor { [weak self] index in
            guard let self else { return }
            openUsage(at: index)
        }
        .disposed(by: rx.disposeBag)

        input.retry.emitOnNextMainActor { [weak self] in
            guard let self else { return }
            reloadRelay.accept(())
        }
        .disposed(by: rx.disposeBag)

        input.exportRequested.emitOnNextMainActor { [weak self] format in
            guard let self, case .ready = state else { return }
            router.trigger(.export(format))
        }
        .disposed(by: rx.disposeBag)

        input.compoundWordsRequested.emitOnNextMainActor { [weak self] in
            guard let self else { return }
            router.trigger(.editCompoundWords)
        }
        .disposed(by: rx.disposeBag)

        input.rankingColumnClicked.emitOnNextMainActor { [weak self] column in
            guard let self else { return }
            rankingOrder = rankingOrder.choosing(column)
            rankingRows = rankingOrder.sorted(rankingRows)
        }
        .disposed(by: rx.disposeBag)

        return Output(
            state: $state.asDriver(),
            preferences: $preferences.asDriver(),
            selectedWordKey: $selectedWordKey.asDriver(),
            usageTitle: $usageTitle.asDriver(),
            usageRows: $usageRows.asDriver(),
            rankingRows: $rankingRows.asDriver(),
            rankingOrder: $rankingOrder.asDriver(),
            wordCountText: $rankingRows.asDriver().map { rows in
                rows.isEmpty ? "" : "\(rows.count.formatted()) \(rows.count == 1 ? "word" : "words")"
            }
            .distinctUntilChanged(),
            usageDetailColumnTitle: $preferences.asDriver().map(\.measure.usageDetailTitle).distinctUntilChanged()
        )
    }

    // MARK: - Reading the names

    private func setupPipelines() {
        // Every window shares the preferences: a change made in another one arrives here too.
        appDefaults.$namingWordCloudPreferences
            .observeOnMainScheduler()
            .subscribeOnNextMainActor { [weak self] storedPreferences in
                guard let self else { return }
                adopt(storedPreferences)
            }
            .disposed(by: rx.disposeBag)

        let sessions = documentState.$runtimeEngineSession.asObservable().distinctUntilChanged { $0 === $1 }
        let readsMembers = $preferences.asObservable().map(\.measure.readsMembers).distinctUntilChanged()
        let generationOptions = appDefaults.$options.distinctUntilChanged()
        let reloads = reloadRelay.asObservable().startWith(())

        Observable.combineLatest(sessions, readsMembers, generationOptions, reloads) { session, readsMembers, _, _ in
            (session, readsMembers)
        }
        .flatMapLatest { [weak self] session, readsMembers -> Observable<SourceEvent> in
            guard let self else { return .empty() }
            return sourceEvents(session: session, readsMembers: readsMembers)
                .withLoadingPlaceholder(
                    .progress(.indexingImage(fractionCompleted: nil)),
                    appearsAfter: LoadingPlaceholderTiming.appearsAfter,
                    staysAtLeast: LoadingPlaceholderTiming.staysAtLeast
                )
        }
        .observeOnMainScheduler()
        .subscribeOnNextMainActor { [weak self] event in
            guard let self else { return }
            handle(event)
        }
        .disposed(by: rx.disposeBag)

        // The image's corpus printed again — under a new transformer, or after
        // it was ejected — is read again when a member measure is on screen.
        sessions
            .observeOnMainScheduler()
            .subscribeOnNextMainActor { [weak self] session in
                guard let self else { return }
                guard let coordinator = session.backgroundWork(forImageAt: imagePath)?.corpusCoordinator else {
                    corpusBuiltSubscription.disposable = Disposables.create()
                    return
                }
                let canonicalImagePath = coordinator.canonicalImagePath(imagePath)
                corpusBuiltSubscription.disposable = coordinator.corpusBuilt.emitOnNextMainActor { [weak self] builtImagePath in
                    guard let self, builtImagePath == canonicalImagePath, preferences.measure.readsMembers, case .ready = state else { return }
                    reloadRelay.accept(())
                }
            }
            .disposed(by: rx.disposeBag)
    }

    private func sourceEvents(session: RuntimeEngineSession, readsMembers: Bool) -> Observable<SourceEvent> {
        Observable.create { [weak self] observer in
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    observer.onCompleted()
                    return
                }
                let event = await loadSource(session: session, readsMembers: readsMembers) { progressState in
                    observer.onNext(.progress(progressState))
                }
                if let event {
                    observer.onNext(event)
                }
                observer.onCompleted()
            }
            return Disposables.create { task.cancel() }
        }
    }

    /// The image's names, indexing the image first and building its corpus
    /// when a member measure needs one; `nil` when cancelled.
    private func loadSource(session: RuntimeEngineSession, readsMembers: Bool, reportProgress: @escaping @MainActor (NamingWordCloudState) -> Void) async -> SourceEvent? {
        let engine = session.engine
        let imagePath = imagePath
        do {
            try await documentState.indexImageForUser(at: imagePath) { progress in
                let fraction = progress.totalCount > 0 ? Double(progress.currentCount) / Double(progress.totalCount) : nil
                await reportProgress(.indexingImage(fractionCompleted: fraction))
            }
            let types = try await engine.objects(in: imagePath)
            try Task.checkCancellation()
            let typeNames = NamingWordCounter.countedTypes(in: types, excludesUnexportedTypes: false).map(NamingWordCounter.typeName(of:))
            let typePrefix = NamingTypePrefix.detect(in: typeNames)
            guard readsMembers else {
                return .loaded(Source(types: types, members: nil, typePrefix: typePrefix))
            }
            guard settings.search.isCorpusEnabled else {
                return .unavailable(.corpusDisabled)
            }
            let members = try await loadMembers(session: session, reportProgress: reportProgress)
            return .loaded(Source(types: types, members: members, typePrefix: typePrefix))
        } catch is CancellationError {
            return nil
        } catch let unavailable as UnavailableError {
            return .unavailable(unavailable.reason)
        } catch let requestError as RuntimeNetworkRequestError where requestError.isUnknownCommand {
            return .unavailable(.peerTooOld)
        } catch {
            if Task.isCancelled { return nil }
            return .failed(error.localizedDescription)
        }
    }

    private func loadMembers(session: RuntimeEngineSession, reportProgress: @escaping @MainActor (NamingWordCloudState) -> Void) async throws -> [RuntimeObjectMembers] {
        let engine = session.engine
        let options = countingOptions
        if let members = try await engine.members(in: imagePath, shownUnder: options) {
            return members
        }
        guard let coordinator = session.backgroundWork(forImageAt: imagePath)?.corpusCoordinator else {
            throw UnavailableError(reason: .corpusUnreachable)
        }
        reportProgress(.buildingCorpus(fractionCompleted: nil))
        coordinator.requestBuild(of: imagePath, isPrioritized: true)
        guard coordinator.buildState(forImagePath: imagePath) != nil else {
            // The coordinator took no request: this engine builds no corpus.
            throw UnavailableError(reason: .corpusUnreachable)
        }
        let canonicalImagePath = coordinator.canonicalImagePath(imagePath)
        buildWait: for try await buildStates in coordinator.$buildStatesByImagePath.asObservable().values {
            switch buildStates[canonicalImagePath] {
            case .building(let progress):
                reportProgress(.buildingCorpus(fractionCompleted: progress.total > 0 ? Double(progress.built) / Double(progress.total) : nil))
            case .built:
                break buildWait
            case .failed(let message):
                throw LoadingError(errorDescription: message)
            case .pending, nil:
                continue
            }
        }
        try Task.checkCancellation()
        guard let members = try await engine.members(in: imagePath, shownUnder: options) else {
            throw LoadingError(errorDescription: "The image's Find corpus was built but could not be read.")
        }
        return members
    }

    /// The document's Generation Options with synthesized accessors and ivars
    /// hidden: a property counts once, not again as its getter, setter and ivar.
    var countingOptions: RuntimeObjectInterface.GenerationOptions {
        var options = currentMergedGenerationOptions
        options.objcHeaderOptions.stripSynthesizedMethods = true
        options.objcHeaderOptions.stripSynthesizedIvars = true
        return options
    }

    private func handle(_ event: SourceEvent) {
        switch event {
        case .progress(let progressState):
            // A progress report of a read that a newer one superseded never
            // replaces content: only a read that takes long shows progress.
            state = progressState
        case .loaded(let loadedSource):
            source = loadedSource
            recount()
        case .unavailable(let reason):
            source = nil
            clearCounts()
            state = .unavailable(reason)
        case .failed(let message):
            source = nil
            clearCounts()
            state = .failed(message: message)
        }
    }

    // MARK: - Counting

    private func adopt(_ updatedPreferences: NamingWordCloudPreferences) {
        let previousPreferences = preferences
        guard updatedPreferences != previousPreferences else { return }
        preferences = updatedPreferences
        if previousPreferences.measure.readsMembers == updatedPreferences.measure.readsMembers {
            recount()
        } else {
            // The names to count change: the read the new measure set off counts them.
            source = nil
        }
    }

    private func recount() {
        guard let source else { return }
        recountTask?.cancel()
        let preferences = preferences
        let options = countingOptions
        // Print Exported Declarations Only, per language, as the content pane applies it.
        let types = source.types.filter { !Self.isHiddenAsUnexported($0, under: options) }
        let members = source.members ?? []
        let configuration = NamingWordCounter.Configuration(
            typePrefix: preferences.removesPrefixes ? source.typePrefix : nil,
            compoundWords: preferences.mergesCompoundWords ? preferences.compoundWords : nil,
            ignoresCommonWords: preferences.ignoresCommonWords,
            excludesUnexportedTypes: false
        )
        recountTask = Task { [weak self] in
            let wordCounts = await Task.detached(priority: .userInitiated) {
                NamingWordCounter.counts(of: preferences.measure, memberGroup: preferences.memberGroup, types: types, members: members, configuration: configuration)
            }.value
            guard !Task.isCancelled, let self else { return }
            apply(wordCounts, preferences: preferences, removedTypePrefix: configuration.typePrefix)
        }
    }

    private static func isHiddenAsUnexported(_ object: RuntimeObject, under options: RuntimeObjectInterface.GenerationOptions) -> Bool {
        guard object.properties.contains(.isNotExported) else { return false }
        switch object.kind {
        case .objc: return options.objcHeaderOptions.printExportedDeclarationsOnly
        case .swift: return options.swiftInterfaceOptions.printExportedDeclarationsOnly
        case .c, .cPlusPlus: return false
        }
    }

    private func apply(_ wordCounts: [NamingWordCount], preferences: NamingWordCloudPreferences, removedTypePrefix: String?) {
        orderedWordCounts = wordCounts
        wordCountsByKey = Dictionary(uniqueKeysWithValues: wordCounts.map { ($0.key, $0) })
        self.removedTypePrefix = removedTypePrefix
        if let selectedWordKey, wordCountsByKey[selectedWordKey] == nil {
            self.selectedWordKey = nil
        }
        updateUsages()
        let rankedWords = wordCounts.map(NamingWordCloudWord.init)
        rankingRows = rankingOrder.sorted(rankedWords)
        guard !wordCounts.isEmpty else {
            state = .unavailable(.nothingToCount)
            return
        }
        let cloudWords = preferences.wordLimit.map { Array(rankedWords.prefix($0)) } ?? rankedWords
        state = .ready(NamingWordCloudContent(measure: preferences.measure, cloudWords: cloudWords, rankedWords: rankedWords, removedTypePrefix: removedTypePrefix))
    }

    private func clearCounts() {
        orderedWordCounts = []
        wordCountsByKey = [:]
        selectedWordKey = nil
        rankingRows = []
        updateUsages()
    }

    // MARK: - Words and names

    /// "Manager — 128 types": a word's tooltip, and the usage list's title.
    public func summary(ofWordWithKey key: String) -> String? {
        guard let wordCount = wordCountsByKey[key] else { return nil }
        return "\(wordCount.word) — \(wordCount.count.formatted()) \(preferences.measure.countedNoun(count: wordCount.count))"
    }

    private func updateUsages() {
        guard let selectedWordKey, let wordCount = wordCountsByKey[selectedWordKey] else {
            usageTitle = Self.noWordSelectedTitle
            usageRows = []
            return
        }
        usageTitle = summary(ofWordWithKey: selectedWordKey) ?? Self.noWordSelectedTitle
        usageRows = wordCount.usages.map(NamingWordCloudUsageRow.init)
    }

    /// Opens a type, or the type declaring a member, in the document's main
    /// window, the way the sidebar opens a row; a member also scrolls to its
    /// declaration and flashes it, as a Find member result does.
    private func openUsage(at index: Int) {
        guard let selectedWordKey, let usages = wordCountsByKey[selectedWordKey]?.usages, usages.indices.contains(index) else { return }
        switch usages[index] {
        case .type(let object):
            documentState.selectionRouter.trigger(.open(object, in: .focusedTab))
        case .member(let member, let object):
            // Located by the name, the declaration line nearest the corpus's.
            let highlight = member.lineNumber.map { lineNumber in
                ContentHighlightRequest(lineNumber: lineNumber, lineText: "", matchRangeInLine: nil, query: member.name, matchMode: .matchingWord, isCaseSensitive: true)
            }
            documentState.selectionRouter.trigger(.open(object, in: .focusedTab, highlighting: highlight))
        }
    }

    // MARK: - Export

    /// The default file name: `AppKit - Type Suffixes.png`.
    public func suggestedFileName(for format: NamingWordCloudExportFormat) -> String {
        "\(imageName) - \(preferences.measure.title).\(format.fileExtension)"
    }

    /// The counts as the format writes them; `nil` for the image, which the
    /// window draws.
    public func exportedData(as format: NamingWordCloudExportFormat) throws -> Data? {
        switch format {
        case .image:
            return nil
        case .csv:
            return Data(NamingWordCountsExport.csv(of: orderedWordCounts).utf8)
        case .json:
            let context = NamingWordCountsExport.Context(
                imagePath: imagePath,
                measure: preferences.measure,
                memberGroup: preferences.memberGroup,
                removedTypePrefix: removedTypePrefix,
                ignoresCommonWords: preferences.ignoresCommonWords,
                mergesCompoundWords: preferences.mergesCompoundWords
            )
            return try NamingWordCountsExport.json(of: orderedWordCounts, context: context)
        }
    }
}

#endif
