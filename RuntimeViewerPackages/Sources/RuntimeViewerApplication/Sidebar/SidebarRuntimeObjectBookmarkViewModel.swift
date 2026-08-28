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
        public let removeBookmark: Signal<Int>
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
            .emitOnNext { [weak self] index in
                guard let self else { return }
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
