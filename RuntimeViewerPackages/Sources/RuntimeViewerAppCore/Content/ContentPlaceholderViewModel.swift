import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// What the content pane shows while it has no object: the hint to select
/// one — or, while the offline service is still reading the window's file,
/// that it is. A window opens on a file the moment the user opens it, and a
/// dyld shared cache keeps the service busy for a while; without this the
/// window would sit empty with no sign that anything is happening.
public final class ContentPlaceholderViewModel: ViewModel<ContentRoute> {
    public enum Placeholder: Equatable {
        /// Nothing is selected.
        case noSelection
        /// The window's offline file is being read, named as the runtime source
        /// picker names it.
        case readingFile(named: String)
    }

    @RxObserved public private(set) var placeholder: Placeholder = .noSelection

    public override init(documentState: DocumentState, router: any Router<ContentRoute>) {
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
    }

    public struct Input {
        public init() {}
    }

    public struct Output {
        public let placeholder: Driver<Placeholder>
    }

    public func transform(_ input: Input) -> Output {
        Output(placeholder: $placeholder.asDriver())
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
