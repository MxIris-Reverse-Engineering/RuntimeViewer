#if os(macOS)

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

public final class SidebarRuntimeObjectBookmarkViewModel: SidebarRuntimeObjectViewModel, @unchecked Sendable {
    public override init(imageNode: RuntimeImageNode, documentState: DocumentState, router: any Router<SidebarRuntimeObjectRoute>) {
        super.init(imageNode: imageNode, documentState: documentState, router: router)

        appDefaults.$objectBookmarksByScopeAndImagePath
            .asObservable()
            .subscribeOnNext { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleReload()
                }
            }
            .disposed(by: rx.disposeBag)
    }

    override func buildRuntimeObjects() async throws -> [RuntimeObject] {
        currentImageObjectBookmarks.map { $0.object }
    }

    /// The bookmarks, once the sidebar's object list has loaded the image: while the list shows its
    /// loading page this page shows it too, with the list's progress, so that no bookmark of the
    /// image opens before the list could open it (`DocumentState.sidebarImageListLoad`). Without a
    /// list on the image — the document has none, as in a test — the bookmarks show at once.
    override func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
        AsyncThrowingStream { continuation in
            let imagePath = imagePath
            // Set up before subscribing: the document's report replays at once, and a list that
            // has settled already ends the stream in the middle of the subscription.
            let subscription = SingleAssignmentDisposable()
            continuation.onTermination = { _ in
                subscription.dispose()
            }
            subscription.setDisposable(
                documentState.$sidebarImageListLoad.asObservable()
                    .map { load -> SidebarImageListLoad.Phase in
                        guard let load, load.imagePath == imagePath else { return .settled }
                        return load.phase
                    }
                    .subscribeOnNextMainActor { [weak self] phase in
                        switch phase {
                        case .loading(let progress):
                            if let progress {
                                continuation.yield(.progress(progress))
                            }
                        case .settled:
                            continuation.yield(.completed(self?.currentImageObjectBookmarks.map(\.object) ?? []))
                            continuation.finish()
                        }
                    }
            )
        }
    }

    private var currentImageObjectBookmarks: [RuntimeObjectBookmark] {
        set {
            var dict = appDefaults.objectBookmarksByScopeAndImagePath
            dict[documentState.runtimeEngine.bookmarkScope.bookmarkKey, default: [:]][imagePath] = newValue
            appDefaults.objectBookmarksByScopeAndImagePath = dict
        }
        get {
            appDefaults.objectBookmarksByScopeAndImagePath[documentState.runtimeEngine.bookmarkScope.bookmarkKey, default: [:]][imagePath, default: []]
        }
    }
    
    @MemberwiseInit(.public)
    public struct Input {
        public let moveBookmark: Signal<OutlineMove>
        /// The bookmark row to remove. A row, not its position: the rows on
        /// screen are the filtered ones, and a position among them names
        /// another bookmark in the stored list.
        public let removeBookmark: Signal<SidebarRuntimeObjectCellViewModel>
    }

    public struct Output {
        public let isMoveBookmarkEnabled: Driver<Bool>
        public let isBookmarkEmpty: Driver<Bool>
    }

    public func transform(_ input: Input) -> Output {
        input.moveBookmark.emitOnNext { [weak self] outlineMove in
            guard let self else { return }
            outlineMove.applyToRoots(&currentImageObjectBookmarks)
        }
        .disposed(by: rx.disposeBag)

        input.removeBookmark
            .emitOnNext { [weak self] cellViewModel in
                guard let self else { return }
                guard let index = currentImageObjectBookmarks.firstIndex(where: { $0.object == cellViewModel.runtimeObject }) else { return }
                currentImageObjectBookmarks.remove(at: index)
            }
            .disposed(by: rx.disposeBag)

        return Output(
            isMoveBookmarkEnabled: $isFiltering.asDriver().not(),
            isBookmarkEmpty: appDefaults.$objectBookmarksByScopeAndImagePath.asDriver(onErrorJustReturn: [:]).map { [weak self] _ in self?.currentImageObjectBookmarks.isEmpty ?? true }
        )
    }
}

extension RuntimeObjectBookmark: @retroactive OutlineNodeType {
    public var children: [RuntimeObjectBookmark] { object.children.map { .init(object: $0) } }
}


#endif
