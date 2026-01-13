import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Ifrit
import MemberwiseInit

public final class SidebarRootDirectoryViewModel: SidebarRootViewModel {
    
    public let nodesSubject = PublishRelay<[RuntimeImageNode]>()
    
    public init(appServices: AppServices, router: any Router<SidebarRootRoute>) {
        super.init(appServices: appServices, router: router, nodesSource: nodesSubject.share().asObservable())
        
        Task {
            await appServices.runtimeEngine
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
        let appServices = appServices
        input.addBookmark
            .emitOnNextMainActor { cellViewModel in
                let bookmark = RuntimeImageBookmark(source: appServices.runtimeEngine.source, imageNode: cellViewModel.node)
                appDefaults.imageBookmarks.append(bookmark)
            }
            .disposed(by: rx.disposeBag)
        return .init()
    }
}
