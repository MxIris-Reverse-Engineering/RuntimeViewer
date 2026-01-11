import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

public final class SidebarRuntimeObjectBookmarkViewModel: SidebarRuntimeObjectViewModel, @unchecked Sendable {
    public override init(imageNode: RuntimeImageNode, appServices: AppServices, router: any Router<SidebarRuntimeObjectRoute>) {
        super.init(imageNode: imageNode, appServices: appServices, router: router)

        appDefaults.$objectBookmarks
            .asObservable()
            .subscribeOnNext { [weak self] _ in
                guard let self else { return }

                Task {
                    try await self.reloadData()
                }
            }
            .disposed(by: rx.disposeBag)
    }

    override func buildRuntimeObjects() async throws -> [RuntimeObject] {
        _ = try await super.buildRuntimeObjects()
        return appDefaults.objectBookmarks.filter { $0.source == appServices.runtimeEngine.source && $0.object.imagePath == imagePath }.map { $0.object }
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let removeBookmark: Signal<Int>
    }

    public struct Output {}

    public func transform(_ input: Input) -> Output {
        input.removeBookmark
            .emitOnNext { [weak self] index in
                guard let self else { return }
                appDefaults.objectBookmarks.remove(at: index)
            }
            .disposed(by: rx.disposeBag)

        return Output()
    }
}
