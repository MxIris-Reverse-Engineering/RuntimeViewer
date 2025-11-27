import Foundation
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit

public final class InspectorClassViewModel: ViewModel<InspectorRoute> {
    @Observed
    private var runtimeObjectName: RuntimeObjectName

    @MemberwiseInit(.public)
    public struct Input {}

    public struct Output {
        public let classHierarchy: Driver<String>
    }

    public func transform(_ input: Input) -> Output {
        return Output(
            classHierarchy: $runtimeObjectName.flatMapLatest { [unowned self] runtimeObjectName in
                do {
                    return try await appServices.runtimeEngine.runtimeObjectHierarchy(for: runtimeObjectName).joined(separator: "\n")
                } catch {
                    print(error.localizedDescription)
                    return runtimeObjectName.displayName
                }
            }.catchAndReturn(runtimeObjectName.displayName).observeOnMainScheduler().asDriverOnErrorJustComplete()
        )
    }

    public init(runtimeObjectName: RuntimeObjectName, appServices: AppServices, router: any Router<InspectorRoute>) {
        self.runtimeObjectName = runtimeObjectName
        super.init(appServices: appServices, router: router)
    }
}
