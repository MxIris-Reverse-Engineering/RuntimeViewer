import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// What the content pane shows while it has no object: the start page — Xcode's
/// initial editor, an Open Quickly field and the engine's recent objects
/// (proposal `editor-start-page`) — or, while the file service is still
/// reading the window's file, that it is. A window opens on a file the moment
/// the user opens it, and a dyld shared cache keeps the service busy for a
/// while; without this the window would sit empty with no sign that anything
/// is happening.
public final class ContentPlaceholderViewModel: ViewModel<ContentRoute> {
    public enum Placeholder: Equatable {
        /// Nothing is selected: the start page.
        case noSelection
        /// The window's file is being read, named as the runtime source
        /// picker names it.
        case readingFile(named: String)
    }

    @RxObserved public private(set) var placeholder: Placeholder = .noSelection

    /// The recent objects the start page lists, most recent first.
    @RxObserved public private(set) var recentItems: [ContentStartPageItemCellViewModel] = []

    /// The editor pane the page is in; the focused pane when `nil`. What the page opens, it opens
    /// from here: the pane takes the focus first.
    private let editorPaneID: EditorPane.ID?

    /// - Parameters:
    ///   - editorPaneID: the editor pane showing the page; the focused pane when `nil`, which is
    ///     what a test that has a single pane passes.
    public init(documentState: DocumentState, router: any Router<ContentRoute>, editorPaneID: EditorPane.ID? = nil) {
        self.editorPaneID = editorPaneID
        super.init(documentState: documentState, router: router)
        documentState.$runtimeEngineSession.asObservable()
            .map(\.engine)
            .flatMapLatest { engine in
                Self.placeholders(for: engine)
            }
            .distinctUntilChanged()
            .observeOnMainScheduler()
            .bind(to: $placeholder)
            .disposed(by: rx.disposeBag)
        followRecentObjects()
    }

    /// Lists the recent objects of the window's engine — read again when the window moves to
    /// another engine — as they are now, and again whenever any window on the engine records one
    /// (`RecentRuntimeObjectsRecorder`). A record on another engine changes nothing here: the store
    /// holds every engine's list, and only this engine's is compared.
    private func followRecentObjects() {
        let recentObjectsByEngine = appDefaults.$recentRuntimeObjectsByEngine
        documentState.$runtimeEngineSession.asObservable()
            .map(\.engine)
            .distinctUntilChanged { $0 === $1 }
            .flatMapLatest { engine in
                recentObjectsByEngine
                    .map { objectsByEngine in RecentRuntimeObjects(engine: engine).objects(in: objectsByEngine) }
                    .distinctUntilChanged(RecentRuntimeObjects.listsAreAlike)
                    .map { recentObjects in (engine, recentObjects) }
            }
            .observeOnMainScheduler()
            .subscribeOnNext { [weak self] engine, recentObjects in
                guard let self else { return }
                let engineName = engine.source.description
                recentItems = recentObjects.map { object in
                    ContentStartPageItemCellViewModel(item: .object(object), engineName: engineName, engineID: engine.engineID)
                }
            }
            .disposed(by: rx.disposeBag)
    }

    public struct Input {
        public init() {}
    }

    public struct Output {
        public let placeholder: Driver<Placeholder>
        public let recentItems: Driver<[ContentStartPageItemCellViewModel]>
    }

    public func transform(_ input: Input) -> Output {
        Output(
            placeholder: $placeholder.asDriver(),
            recentItems: $recentItems.asDriver()
        )
    }

    /// `.readingFile` while `engine` reads a file and has not connected to
    /// the process reading it — the first read, and every later one after a
    /// suspension or a new dependency cache — and `.noSelection` otherwise.
    /// A read is a piece of work like any other the panes wait for, so it
    /// shows through the shared loading timing: one that finishes quickly
    /// shows no placeholder, and one that shows it keeps it up long enough
    /// not to blink.
    static func placeholders(for engine: RuntimeEngine) -> Observable<Placeholder> {
        guard case .file(let name, _) = engine.source else { return .just(.noSelection) }
        let isReading = engine.statePublisher.asObservable()
            .map { state in state == .initializing || state == .connecting }
            .distinctUntilChanged()
            .observeOnMainScheduler()
            .share(replay: 1)
        // One read at a time, each to its end — its placeholder's minimum
        // time included — so the end of one read never lands on the next.
        return isReading.concatMap { reading -> Observable<Placeholder> in
            guard reading else { return .just(.noSelection) }
            let readingEnded = isReading
                .filter { !$0 }
                .take(1)
                .map { _ in Placeholder.noSelection }
            return readingEnded.withLoadingPlaceholder(
                .readingFile(named: name),
                appearsAfter: LoadingPlaceholderTiming.appearsAfter,
                staysAtLeast: LoadingPlaceholderTiming.staysAtLeast
            )
        }
    }
}
