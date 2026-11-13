import Foundation
import Testing
import RxSwift
import RuntimeViewerArchitectures
@testable import RuntimeViewerCore
@testable import RuntimeViewerAppCore

/// What an editor pane shows for an image chosen in its jump bar (proposal `editor-jump-bar`): the
/// image indexed first, its progress in the pane, then the page naming it; or why it failed, with
/// Try Again. The indexing is scripted, except where the real engine's own path is the subject.
@Suite("ContentImageViewModel")
@MainActor
struct ContentImageViewModelTests {
    private let router = MockRouter<ContentRoute>()
    private let retryRelay = PublishRelay<Void>()

    private static let objects = [
        Fixtures.runtimeObject(name: "Beta", kind: .objc(.type(.class))),
        Fixtures.runtimeObject(name: "Alpha", kind: .objc(.type(.class))),
        Fixtures.runtimeObject(name: "Delegate", kind: .objc(.type(.protocol))),
    ]

    private func makeViewModel(
        in environment: ViewModelTestEnvironment,
        indexer: @escaping ContentImageViewModel.Indexer
    ) -> (ContentImageViewModel, ContentImageViewModel.Output) {
        let viewModel = environment.make {
            ContentImageViewModel(imagePath: Fixtures.sampleImagePath, documentState: environment.documentState, router: router, indexer: indexer)
        }
        let output = viewModel.transform(.init(retryClicked: retryRelay.asSignal()))
        return (viewModel, output)
    }

    @Test("an image indexed already shows its page without the progress view in between")
    func indexedImageShowsItsPageAtOnce() async throws {
        let startedAt = ContinuousClock.now
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(in: environment) { _, _ in Self.objects }
        defer { withExtendedLifetime(viewModel) {} }
        var seenStates: [ContentImageViewModel.State] = []
        let subscription = output.state.driveOnNext { seenStates.append($0) }
        defer { subscription.dispose() }

        let shownState = try await nextValue(from: output.state) { if case .indexed = $0 { true } else { false } }

        #expect(shownState == .indexed(ContentImageViewModel.Summary(objects: Self.objects)))
        #expect(viewModel.imageName == "Sample")
        // The progress view only comes up once the work has taken `appearsAfter`; a run slowed down
        // past that by a loaded machine may show it, which says nothing about the page.
        if ContinuousClock.now - startedAt < .milliseconds(Int(LoadingPlaceholderTiming.appearsAfter * 1000)) {
            #expect(!seenStates.contains(.indexing))
        }
    }

    @Test("a slow image shows the progress view with the indexing's progress, then its page")
    func slowImageShowsItsProgress() async throws {
        let environment = ViewModelTestEnvironment()
        let progress = RuntimeObjectsLoadingProgress(phase: .loadingObjCClasses, itemDescription: "", currentCount: 3, totalCount: 10)
        let (viewModel, output) = makeViewModel(in: environment) { _, reportProgress in
            await reportProgress(progress)
            try await Task.sleep(for: .milliseconds(600))
            return Self.objects
        }
        defer { withExtendedLifetime(viewModel) {} }

        #expect(try await nextValue(from: output.state) { $0 == .indexing } == .indexing)
        let shownProgress = try await nextValue(from: output.indexingProgress) { $0.itemCount == "3/10" }
        #expect(shownProgress.description == progress.phase.displayDescription)
        #expect(try await nextValue(from: output.state) { $0 != .indexing && $0 != .starting } == .indexed(ContentImageViewModel.Summary(objects: Self.objects)))
    }

    @Test("an image that fails says why, and Try Again tries again")
    func failureAndTryAgain() async throws {
        let environment = ViewModelTestEnvironment()
        let attempts = AttemptCounter()
        let (viewModel, output) = makeViewModel(in: environment) { _, _ in
            if await attempts.next() == 1 {
                throw ScriptedIndexingFailure()
            }
            return Self.objects
        }
        defer { withExtendedLifetime(viewModel) {} }

        let failure = try await nextValue(from: output.state) { if case .failed = $0 { true } else { false } }
        guard case .failed(let message) = failure else { return }
        #expect(message.contains("Sample"))

        retryRelay.accept(())

        #expect(try await nextValue(from: output.state) { if case .indexed = $0 { true } else { false } } == .indexed(ContentImageViewModel.Summary(objects: Self.objects)))
    }

    @Test("the page counts the image's objects by kind, in the order of the sidebar's sections")
    func summaryCountsByKind() {
        let summary = ContentImageViewModel.Summary(objects: Self.objects)

        #expect(summary.objectCounts.map(\.count) == [2, 1])
        #expect(summary.objectCounts.map(\.kindTitle) == [RuntimeObjectKind.objc(.type(.class)).description, RuntimeObjectKind.objc(.type(.protocol)).description])
        #expect(summary.objectCount == 3)
    }

    @Test("the real indexing builds the objects of an image that is loaded but not indexed, reporting progress")
    func realIndexingOfALoadedImage() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ContentImageViewModelTests.loadedImage")
        #expect(try await engine.isImageLoaded(path: TestImages.libobjc))
        #expect(try await engine.isImageIndexed(path: TestImages.libobjc) == false)

        let objects = try await ContentImageViewModel.index(imageAt: TestImages.libobjc, on: engine) { _ in }

        #expect(objects.contains { $0.name == "NSObject" })
        #expect(try await engine.isImageIndexed(path: TestImages.libobjc))
    }
}

/// What a scripted indexer throws to fail an attempt.
private struct ScriptedIndexingFailure: Error {}

/// Counts the attempts a scripted indexer makes, from any task.
private actor AttemptCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
