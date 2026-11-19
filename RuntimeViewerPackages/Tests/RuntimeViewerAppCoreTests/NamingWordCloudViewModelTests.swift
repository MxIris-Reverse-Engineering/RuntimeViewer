#if os(macOS)

import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The naming word cloud window's view model against a real engine on
/// libobjc: the type measures counted from the object list, the member
/// measures from the Find corpus it asks the document's coordinator to build,
/// selection, opening a name in the main window, the shared preferences, and
/// what the exports hold.
@Suite("NamingWordCloudViewModel", .serialized)
@MainActor
struct NamingWordCloudViewModelTests {
    private struct Harness {
        let environment: ViewModelTestEnvironment
        let viewModel: NamingWordCloudViewModel
        let router: MockRouter<NamingWordCloudRoute>
        let output: NamingWordCloudViewModel.Output
        let preferenceChanges: PublishRelay<NamingWordCloudPreferenceChange>
        let wordSelections: PublishRelay<String?>
        let usageClicks: PublishRelay<Int>
        let exportRequests: PublishRelay<NamingWordCloudExportFormat>
        let rankingColumnClicks: PublishRelay<NamingWordRankingOrder.Column>

        func readyContent(timeout: TimeInterval = 60) async throws -> NamingWordCloudContent {
            let state = try await nextValue(from: output.state, timeout: timeout) { state in
                if case .ready = state { return true }
                return false
            }
            guard case .ready(let content) = state else { throw ExpectedReady() }
            return content
        }
    }

    private struct ExpectedReady: Error {}

    private static func makeHarness(
        engineID: String,
        isCorpusEnabled: Bool = false,
        measure: NamingWordMeasure = .typeSuffixes
    ) async throws -> Harness {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: engineID, loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.indexing.isEnabled = false
        environment.settings.search.isCorpusEnabled = isCorpusEnabled
        var preferences = NamingWordCloudPreferences()
        preferences.measure = measure
        environment.appDefaults.namingWordCloudPreferences = preferences
        if isCorpusEnabled {
            environment.startBackgroundWork()
        }
        let router = MockRouter<NamingWordCloudRoute>()
        let viewModel = environment.make {
            NamingWordCloudViewModel(imagePath: TestImages.libobjc, documentState: environment.documentState, router: router)
        }
        let preferenceChanges = PublishRelay<NamingWordCloudPreferenceChange>()
        let wordSelections = PublishRelay<String?>()
        let usageClicks = PublishRelay<Int>()
        let exportRequests = PublishRelay<NamingWordCloudExportFormat>()
        let rankingColumnClicks = PublishRelay<NamingWordRankingOrder.Column>()
        let output = viewModel.transform(.init(
            preferenceChanged: preferenceChanges.asSignal(),
            wordSelected: wordSelections.asSignal(),
            usageClicked: usageClicks.asSignal(),
            retry: .empty(),
            exportRequested: exportRequests.asSignal(),
            compoundWordsRequested: .empty(),
            rankingColumnClicked: rankingColumnClicks.asSignal()
        ))
        return Harness(
            environment: environment,
            viewModel: viewModel,
            router: router,
            output: output,
            preferenceChanges: preferenceChanges,
            wordSelections: wordSelections,
            usageClicks: usageClicks,
            exportRequests: exportRequests,
            rankingColumnClicks: rankingColumnClicks
        )
    }

    @Test("the type measures are counted from the object list once the image is indexed, without a corpus")
    func typeMeasures() async throws {
        let harness = try await Self.makeHarness(engineID: "NamingWordCloudViewModelTests.types")
        defer { withExtendedLifetime(harness.viewModel) {} }

        let content = try await harness.readyContent()

        #expect(content.measure == .typeSuffixes)
        #expect(!content.cloudWords.isEmpty)
        #expect(content.rankedWords.count >= content.cloudWords.count)
        #expect(!content.legend.isEmpty)
        #expect(content.legend.allSatisfy(NamingWordMeasure.typeSuffixes.categories.contains))
        #expect(harness.viewModel.windowTitle == "Naming Word Cloud")
        #expect(harness.viewModel.windowSubtitle == "libobjc.A")
    }

    @Test("the ranking lists every word counted, the most common first, and says how many there are")
    func rankingRowsAndWordCount() async throws {
        let harness = try await Self.makeHarness(engineID: "NamingWordCloudViewModelTests.ranking")
        defer { withExtendedLifetime(harness.viewModel) {} }
        let content = try await harness.readyContent()

        let rows = try await nextValue(from: harness.output.rankingRows) { !$0.isEmpty }
        #expect(rows == NamingWordRankingOrder.mostCommonFirst.sorted(content.rankedWords))
        let wordCountText = try await nextValue(from: harness.output.wordCountText) { !$0.isEmpty }
        #expect(wordCountText == "\(content.rankedWords.count.formatted()) \(content.rankedWords.count == 1 ? "word" : "words")")
        #expect(try await nextValue(from: harness.output.usageDetailColumnTitle) == "Kind")
    }

    @Test("a click on the Word header orders the ranking from A, and a second one reverses it")
    func rankingHeaderClicks() async throws {
        let harness = try await Self.makeHarness(engineID: "NamingWordCloudViewModelTests.rankingHeader")
        defer { withExtendedLifetime(harness.viewModel) {} }
        let content = try await harness.readyContent()
        let byWord = NamingWordRankingOrder(column: .word, isAscending: true)

        harness.rankingColumnClicks.accept(.word)

        _ = try await nextValue(from: harness.output.rankingOrder) { $0 == byWord }
        _ = try await nextValue(from: harness.output.rankingRows) { $0 == byWord.sorted(content.rankedWords) }

        harness.rankingColumnClicks.accept(.word)

        let reversed = NamingWordRankingOrder(column: .word, isAscending: false)
        _ = try await nextValue(from: harness.output.rankingOrder) { $0 == reversed }
        _ = try await nextValue(from: harness.output.rankingRows) { $0 == reversed.sorted(content.rankedWords) }
    }

    @Test("the usage list's title says no word is selected until one is")
    func usageTitleSaysNoWordSelectedWithoutSelection() async throws {
        let harness = try await Self.makeHarness(engineID: "NamingWordCloudViewModelTests.noSelection")
        defer { withExtendedLifetime(harness.viewModel) {} }
        _ = try await harness.readyContent()

        #expect(try await nextValue(from: harness.output.usageTitle) == NamingWordCloudViewModel.noWordSelectedTitle)
    }

    @Test("selecting a word lists the names holding it, and clicking one opens it in the main window")
    func selectionAndNavigation() async throws {
        let harness = try await Self.makeHarness(engineID: "NamingWordCloudViewModelTests.selection")
        defer { withExtendedLifetime(harness.viewModel) {} }
        let content = try await harness.readyContent()
        let word = try #require(content.rankedWords.first)

        harness.wordSelections.accept(word.key)

        let rows = try await nextValue(from: harness.output.usageRows) { !$0.isEmpty }
        #expect(rows.count == word.count)
        let title = try await nextValue(from: harness.output.usageTitle) { $0.hasPrefix("\(word.word) — ") }
        #expect(harness.viewModel.summary(ofWordWithKey: word.key) == title)

        harness.usageClicks.accept(0)

        try await waitUntil { harness.environment.documentState.selectedRuntimeObject?.displayName == rows[0].name }
    }

    @Test("a word no longer counted is deselected")
    func staleSelectionCleared() async throws {
        let harness = try await Self.makeHarness(engineID: "NamingWordCloudViewModelTests.staleSelection")
        defer { withExtendedLifetime(harness.viewModel) {} }
        _ = try await harness.readyContent()

        harness.wordSelections.accept("no-such-word")

        #expect(try await nextValue(from: harness.output.selectedWordKey) == nil)
    }

    @Test("the member measures say how to turn the corpus on while Settings › Search has it off")
    func memberMeasuresWithoutCorpus() async throws {
        let harness = try await Self.makeHarness(engineID: "NamingWordCloudViewModelTests.corpusOff", measure: .memberWords)
        defer { withExtendedLifetime(harness.viewModel) {} }

        let state = try await nextValue(from: harness.output.state, timeout: 60) { state in
            if case .unavailable = state { return true }
            return false
        }

        #expect(state == .unavailable(.corpusDisabled))
    }

    @Test("the member measures have the document's coordinator build the corpus, then count member names")
    func memberMeasuresBuildTheCorpus() async throws {
        let harness = try await Self.makeHarness(engineID: "NamingWordCloudViewModelTests.corpusOn", isCorpusEnabled: true, measure: .methodFirstWords)
        defer { withExtendedLifetime(harness.viewModel) {} }

        let content = try await harness.readyContent(timeout: 180)

        #expect(content.measure == .methodFirstWords)
        #expect(content.rankedWords.allSatisfy { $0.word == $0.word.lowercased() })
        #expect(content.legend.allSatisfy(NamingWordMeasure.methodFirstWords.categories.contains))
        let built = harness.environment.documentState.runtimeEngineSession.backgroundWork(forImageAt: TestImages.libobjc)?.corpusCoordinator.buildState(forImagePath: TestImages.libobjc)
        #expect(built?.isBuilt == true, "the build went through the document's corpus coordinator")

        let word = try #require(content.rankedWords.first)
        harness.wordSelections.accept(word.key)
        let rows = try await nextValue(from: harness.output.usageRows) { !$0.isEmpty }
        harness.usageClicks.accept(0)
        try await waitUntil { harness.environment.documentState.selectedRuntimeObject?.displayName == rows[0].detail }
    }

    @Test("a change of preference is stored for every window and counts again")
    func preferenceChanges() async throws {
        let harness = try await Self.makeHarness(engineID: "NamingWordCloudViewModelTests.preferences")
        defer { withExtendedLifetime(harness.viewModel) {} }
        let suffixes = try await harness.readyContent()

        harness.preferenceChanges.accept(.measure(.typeWords))

        let words = try await nextValue(from: harness.output.state, timeout: 60) { state in
            if case .ready(let content) = state { return content.measure == .typeWords }
            return false
        }
        guard case .ready(let wordsContent) = words else { return }
        #expect(wordsContent.rankedWords.count >= suffixes.rankedWords.count)
        #expect(harness.environment.appDefaults.namingWordCloudPreferences.measure == .typeWords)

        harness.preferenceChanges.accept(.wordLimit(1))
        let limited = try await nextValue(from: harness.output.state, timeout: 60) { state in
            if case .ready(let content) = state { return content.cloudWords.count == 1 }
            return false
        }
        guard case .ready(let limitedContent) = limited else { return }
        #expect(limitedContent.rankedWords.count == wordsContent.rankedWords.count, "the ranking keeps every word")
    }

    @Test("the exports hold every counted word, under a name made of the image and the measure")
    func exports() async throws {
        let harness = try await Self.makeHarness(engineID: "NamingWordCloudViewModelTests.exports")
        defer { withExtendedLifetime(harness.viewModel) {} }
        let content = try await harness.readyContent()

        let csv = try #require(try harness.viewModel.exportedData(as: .csv))
        let lines = String(decoding: csv, as: UTF8.self).split(separator: "\n")
        #expect(lines.first == "word,count")
        #expect(lines.count == content.rankedWords.count + 1)
        #expect(try harness.viewModel.exportedData(as: .json) != nil)
        #expect(try harness.viewModel.exportedData(as: .image) == nil)
        #expect(harness.viewModel.suggestedFileName(for: .image) == "libobjc.A - Type Suffixes.png")

        harness.exportRequests.accept(.csv)
        try await waitUntil { harness.router.triggeredRoutes.contains { if case .export(.csv) = $0 { return true } else { return false } } }
    }
}

/// The Compound Words sheet: words added and presets removed are stored as
/// changes to the presets, and a single word is refused.
@Suite("NamingCompoundWordsViewModel")
@MainActor
struct NamingCompoundWordsViewModelTests {
    @Test("adding, removing and restoring compound words changes the stored preferences")
    func editing() async throws {
        let environment = ViewModelTestEnvironment()
        let router = MockRouter<NamingWordCloudRoute>()
        let viewModel = environment.make {
            NamingCompoundWordsViewModel(documentState: environment.documentState, router: router)
        }
        defer { withExtendedLifetime(viewModel) {} }
        let additions = PublishRelay<String>()
        let removals = PublishRelay<[Int]>()
        let restorations = PublishRelay<Void>()
        let dones = PublishRelay<Void>()
        let output = viewModel.transform(.init(addWord: additions.asSignal(), removeRows: removals.asSignal(), restorePresets: restorations.asSignal(), done: dones.asSignal()))
        var refusals: [String] = []
        let refusalSubscription = output.refusal.emitOnNext { refusals.append($0) }
        defer { refusalSubscription.dispose() }

        #expect(viewModel.rows.map(\.word) == NamingCompoundWords.presetWords)

        additions.accept("Provider")
        await Self.eventually { refusals.count == 1 }

        additions.accept(" VisualProvider ")
        await Self.eventually { viewModel.rows.last == .init(word: "VisualProvider", isPreset: false) }
        #expect(environment.appDefaults.namingWordCloudPreferences.addedCompoundWords == ["VisualProvider"])
        #expect(refusals.count == 1)

        let dataSourceIndex = try #require(viewModel.rows.firstIndex { $0.word == "DataSource" })
        removals.accept([dataSourceIndex])
        await Self.eventually { !viewModel.rows.contains { $0.word == "DataSource" } }
        #expect(environment.appDefaults.namingWordCloudPreferences.removedPresetCompoundWords == ["DataSource"])

        additions.accept("datasource")
        await Self.eventually { viewModel.rows.contains { $0.word == "DataSource" && $0.isPreset } }
        #expect(environment.appDefaults.namingWordCloudPreferences.removedPresetCompoundWords.isEmpty, "adding a removed preset brings it back")

        removals.accept([0])
        await Self.eventually { viewModel.rows.filter(\.isPreset).count == NamingCompoundWords.presetWords.count - 1 }
        restorations.accept(())
        await Self.eventually { viewModel.rows.filter(\.isPreset).count == NamingCompoundWords.presetWords.count }

        dones.accept(())
        await Self.eventually { router.triggeredRoutes.contains { if case .closeCompoundWords = $0 { return true } else { return false } } }
    }

    /// Waits up to five seconds for `condition`, and records an issue at the
    /// caller's line when it never holds.
    private static func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }
}

#endif
