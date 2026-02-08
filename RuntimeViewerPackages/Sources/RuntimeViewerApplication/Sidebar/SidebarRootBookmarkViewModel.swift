import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

public final class SidebarRootBookmarkViewModel: SidebarRootViewModel {
    
    override var isFilterEmptyNodes: Bool { false }
    
    public init(appState: AppState, router: any Router<SidebarRootRoute>) {
        @Dependency(\.appDefaults)
        var appDefaults

        let nodesSource = appDefaults.$imageBookmarks.map { $0.compactMap { if $0.source == appState.runtimeEngine.source { $0.imageNode } else { nil } } }

        super.init(appState: appState, router: router, nodesSource: nodesSource)
    }
    
    @MemberwiseInit(.public)
    public struct Input {
        public let removeBookmark: Signal<Int>
    }
    
    public struct Output {
        public let isEmptyBookmark: Driver<Bool>
    }
    
    public func transform(_ input: Input) -> Output {
        input.removeBookmark
            .emitOnNext { [weak self] index in
                guard let self else { return }
                appDefaults.imageBookmarks.remove(at: index)
            }
            .disposed(by: rx.disposeBag)
        return Output(
            isEmptyBookmark: appDefaults.$imageBookmarks.asDriver(onErrorJustReturn: []).map { $0.isEmpty }
        )
    }
}
