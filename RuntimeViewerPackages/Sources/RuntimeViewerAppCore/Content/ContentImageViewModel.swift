import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

/// What an editor pane shows for an image chosen in its jump bar, before any of its objects
/// (proposal `editor-jump-bar`): the image indexed first when it is not — loaded first when the
/// engine's process has not loaded it — with the progress in the pane, then a page naming the image
/// and how many objects of each kind it has. Its objects are chosen from the jump bar, whose last
/// component lists them once they are read. The sidebar does not move.
///
/// The work is the same the sidebar does to open an image, and runs as a foreground load: the
/// engine's background indexing waits for it. A pane that moves on does not stop it — the engine
/// cannot, and what it builds is used anyway.
public final class ContentImageViewModel: ViewModel<ContentRoute> {
    public enum State: Equatable {
        /// The first moments of the work: nothing shows yet, so an image indexed already appears
        /// without a flash of progress.
        case starting

        /// The image is being indexed; `indexingProgress` says how far.
        case indexing

        case indexed(Summary)

        case failed(message: String)
    }

    /// What the page says about an indexed image.
    public struct Summary: Equatable, Sendable {
        /// How many objects of each kind the image has, in the order of the sidebar's kind sections.
        public let objectCounts: [ObjectCount]

        public var objectCount: Int {
            objectCounts.reduce(0) { $0 + $1.count }
        }

        public init(objects: [RuntimeObject]) {
            var counts: [RuntimeObjectKind: Int] = [:]
            for object in objects {
                counts[object.kind, default: 0] += 1
            }
            self.objectCounts = counts.keys.sorted().map { ObjectCount(kindTitle: $0.description, count: counts[$0] ?? 0) }
        }
    }

    public struct ObjectCount: Equatable, Sendable {
        /// The kind as the sidebar's section header names it.
        public let kindTitle: String

        public let count: Int
    }

    /// How far the indexing has come, as the sidebar's loading view shows it.
    public struct IndexingProgress: Equatable, Sendable {
        public let fraction: Double

        public let description: String

        /// "120/3400", or empty while the phase counts nothing.
        public let itemCount: String

        public static let preparing = IndexingProgress(fraction: 0, description: "Preparing...", itemCount: "")

        public init(fraction: Double, description: String, itemCount: String) {
            self.fraction = fraction
            self.description = description
            self.itemCount = itemCount
        }

        init(_ progress: RuntimeObjectsLoadingProgress) {
            self.init(
                fraction: progress.overallFraction,
                description: progress.phase.displayDescription,
                itemCount: progress.totalCount > 0 ? "\(progress.currentCount)/\(progress.totalCount)" : ""
            )
        }
    }

    public let imagePath: String

    public let imageName: String

    @RxObserved public private(set) var state: State = .starting

    /// The progress of the indexing under way, for the progress view `.indexing` shows; it says
    /// nothing in any other state.
    @RxObserved public private(set) var indexingProgress: IndexingProgress = .preparing

    private let retryRelay = PublishRelay<Void>()

    /// The work that shows `imagePath`. Injectable so tests can script it; the default indexes the
    /// image on the document's engine.
    typealias Indexer = @Sendable (_ imagePath: String, _ reportProgress: @escaping @Sendable (RuntimeObjectsLoadingProgress) async -> Void) async throws -> [RuntimeObject]

    public convenience init(imagePath: String, documentState: DocumentState, router: any Router<ContentRoute>) {
        self.init(imagePath: imagePath, documentState: documentState, router: router, indexer: nil)
    }

    init(imagePath: String, documentState: DocumentState, router: any Router<ContentRoute>, indexer: Indexer?) {
        self.imagePath = imagePath
        self.imageName = NavigationEntry.imageName(ofImageAt: imagePath)
        let engine = documentState.runtimeEngine
        // An image indexed already is read; any other is the user's own load, which the Report's
        // Manual Loading records along with this page.
        let resolvedIndexer: Indexer = indexer ?? { [weak documentState] imagePath, reportProgress in
            if try await engine.isImageIndexed(path: imagePath) {
                return try await engine.objects(in: imagePath)
            }
            guard let documentState else {
                return try await Self.index(imageAt: imagePath, on: engine, reportProgress: reportProgress)
            }
            return try await documentState.recordingManualLoad(ofImageAt: imagePath) { recordProgress in
                try await Self.index(imageAt: imagePath, on: engine) { progress in
                    await reportProgress(progress)
                    await recordProgress(progress)
                }
            }
        }
        super.init(documentState: documentState, router: router)

        // One attempt at a time; Try Again starts another. Only the outcome goes through the
        // loading timing, so an image indexed already shows its page at once, and a slow one
        // shows the progress view for long enough not to blink. The progress itself goes to its
        // own property: it is what the progress view draws, not a state of the page.
        retryRelay.asObservable()
            .startWith(())
            .flatMapLatest { [weak self, imagePath] _ -> Observable<State> in
                MainActor.assumeIsolated {
                    self?.indexingProgress = .preparing
                }
                return Observable<State>.async { [weak self] in
                    let objects = try await resolvedIndexer(imagePath) { [weak self] progress in
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            indexingProgress = IndexingProgress(progress)
                        }
                    }
                    return .indexed(Summary(objects: objects))
                }
                .catch { error in .just(.failed(message: Self.message(for: error, imageName: NavigationEntry.imageName(ofImageAt: imagePath)))) }
                .withLoadingPlaceholder(
                    .indexing,
                    appearsAfter: LoadingPlaceholderTiming.appearsAfter,
                    staysAtLeast: LoadingPlaceholderTiming.staysAtLeast
                )
            }
            .observeOnMainScheduler()
            .bind(to: $state)
            .disposed(by: rx.disposeBag)
    }

    @MemberwiseInit(.public)
    public struct Input {
        /// Try Again, after the image could not be loaded.
        public let retryClicked: Signal<Void>
    }

    public struct Output {
        public let state: Driver<State>
        public let indexingProgress: Driver<IndexingProgress>
    }

    public func transform(_ input: Input) -> Output {
        input.retryClicked.emitOnNext { [weak self] in
            guard let self else { return }
            retryRelay.accept(())
        }
        .disposed(by: rx.disposeBag)

        return Output(
            state: $state.asDriver(),
            indexingProgress: $indexingProgress.asDriver()
        )
    }

    /// Indexes the image at `imagePath` on `engine` the way the sidebar opens one, and returns its
    /// objects: read at once when the image is indexed, built when it is loaded but not indexed,
    /// loaded first when the engine's process has not loaded it.
    nonisolated static func index(
        imageAt imagePath: String,
        on engine: RuntimeEngine,
        reportProgress: @escaping @Sendable (RuntimeObjectsLoadingProgress) async -> Void
    ) async throws -> [RuntimeObject] {
        if try await engine.isImageIndexed(path: imagePath) {
            return try await engine.objects(in: imagePath)
        }
        if try await engine.isImageLoaded(path: imagePath) {
            var objects: [RuntimeObject] = []
            for try await event in await engine.objectsWithProgress(in: imagePath) {
                switch event {
                case .progress(let progress):
                    await reportProgress(progress)
                case .completed(let completedObjects):
                    objects = completedObjects
                }
            }
            return objects
        }
        try await engine.loadImageForUser(at: imagePath, reportProgress: reportProgress)
        return try await engine.objects(in: imagePath)
    }

    /// What the page says when the image could not be shown: dyld's own message when it refused
    /// to load the image.
    nonisolated static func message(for error: any Error, imageName: String) -> String {
        if let dyldOpenError = error as? DyldOpenError, let message = dyldOpenError.message {
            return message
        }
        return "\(imageName) could not be loaded: \(error.localizedDescription)"
    }
}
