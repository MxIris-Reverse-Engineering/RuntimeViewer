import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

public final class SidebarRootDirectoryViewModel: SidebarRootViewModel {
    
    public let nodesSubject = BehaviorSubject<[RuntimeImageNode]>(value: [])
    
    public init(documentState: DocumentState, router: any Router<SidebarRootRoute>) {
        super.init(documentState: documentState, router: router, nodesSource: nodesSubject.asObservable())
        
        Task {
            await documentState.runtimeEngine
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
        let documentState = documentState
        input.addBookmark
            .emitOnNextMainActor { cellViewModel in
                let runtimeSource = documentState.runtimeEngine.source
                let bookmark = RuntimeImageBookmark(source: runtimeSource, imageNode: cellViewModel.node)
                appDefaults.imageBookmarksByRuntimeSource[runtimeSource, default: []].append(bookmark)
            }
            .disposed(by: rx.disposeBag)
        return .init()
    }
}
