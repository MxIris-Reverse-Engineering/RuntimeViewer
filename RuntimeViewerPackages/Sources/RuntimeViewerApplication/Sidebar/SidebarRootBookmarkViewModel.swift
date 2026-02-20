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

        let nodesSource = appDefaults.$imageBookmarksByRuntimeSource.map { $0[documentState.runtimeEngine.source, default: []].map(\.imageNode) }

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
            outlineMove.applyToRoots(&appDefaults.imageBookmarksByRuntimeSource[documentState.runtimeEngine.source, default: []])
        }
        .disposed(by: rx.disposeBag)

        input.removeBookmark
            .emitOnNext { [weak self] index in
                guard let self else { return }
                appDefaults.imageBookmarksByRuntimeSource[documentState.runtimeEngine.source, default: []].remove(at: index)
            }
            .disposed(by: rx.disposeBag)
        #if os(macOS)
        return Output(
            isMoveBookmarkEnabled: $isFiltering.asDriver().not(),
            isBookmarkEmpty: appDefaults.$imageBookmarks.asDriver(onErrorJustReturn: []).map { $0.isEmpty }
        )
        #else
        return Output(
            isBookmarkEmpty: appDefaults.$imageBookmarks.asDriver(onErrorJustReturn: []).map { $0.isEmpty }
        )
        #endif
    }
}

extension RuntimeImageBookmark: @retroactive OutlineNodeType {
    public var children: [RuntimeImageBookmark] { imageNode.children.map { .init(source: source, imageNode: $0) } }
}
