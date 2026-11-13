#if os(macOS)

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

public final class SidebarRootBookmarkViewModel: SidebarRootViewModel {
    override var isFilterEmptyNodes: Bool {
        false
    }

    public init(documentState: DocumentState, router: any Router<SidebarRootRoute>) {
        @Dependency(\.appDefaults)
        var appDefaults

        let bookmarkKey = documentState.runtimeEngine.bookmarkScope.bookmarkKey
        let nodesSource = appDefaults.$imageBookmarksByScope.map { $0[bookmarkKey, default: []].map(\.imageNode) }

        super.init(documentState: documentState, router: router, nodesSource: nodesSource)
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
            let bookmarkKey = documentState.runtimeEngine.bookmarkScope.bookmarkKey
            var bookmarks = appDefaults.imageBookmarksByScope
            var scopedBookmarks = bookmarks[bookmarkKey, default: []]
            outlineMove.applyToRoots(&scopedBookmarks)
            bookmarks[bookmarkKey] = scopedBookmarks
            appDefaults.imageBookmarksByScope = bookmarks
        }
        .disposed(by: rx.disposeBag)

        input.removeBookmark
            .emitOnNext { [weak self] index in
                guard let self else { return }
                var bookmarks = appDefaults.imageBookmarksByScope
                bookmarks[documentState.runtimeEngine.bookmarkScope.bookmarkKey, default: []].remove(at: index)
                appDefaults.imageBookmarksByScope = bookmarks
            }
            .disposed(by: rx.disposeBag)
        return Output(
            isMoveBookmarkEnabled: $isFiltering.asDriver().not(),
            isBookmarkEmpty: appDefaults.$imageBookmarksByScope.asDriver(onErrorJustReturn: [:]).map { $0[self.documentState.runtimeEngine.bookmarkScope.bookmarkKey, default: []].isEmpty }
        )
    }
}

extension RuntimeImageBookmark: @retroactive OutlineNodeType {
    public var children: [RuntimeImageBookmark] { imageNode.children.map { .init(imageNode: $0) } }
}


#endif
