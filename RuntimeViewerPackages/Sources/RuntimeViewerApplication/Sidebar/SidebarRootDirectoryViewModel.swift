import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

public final class SidebarRootDirectoryViewModel: SidebarRootViewModel {
    
    public let nodesSubject = BehaviorSubject<[RuntimeImageNode]>(value: [])
    
    public init(appState: AppState, router: any Router<SidebarRootRoute>) {
        super.init(appState: appState, router: router, nodesSource: nodesSubject.asObservable())
        
        Task {
            await appState.runtimeEngine
                .$imageNodes
                .asObservable()
                .bind(to: nodesSubject)
                .disposed(by: rx.disposeBag)
        }
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let addBookmark: Signal<SidebarRootCellViewModel>
    }

    public struct Output {}

    public func transform(_ input: Input) -> Output {
        let appDefaults = appDefaults
        let appState = appState
        input.addBookmark
            .emitOnNextMainActor { cellViewModel in
                let bookmark = RuntimeImageBookmark(source: appState.runtimeEngine.source, imageNode: cellViewModel.node)
                appDefaults.imageBookmarks.append(bookmark)
            }
            .disposed(by: rx.disposeBag)
        return .init()
    }
}
