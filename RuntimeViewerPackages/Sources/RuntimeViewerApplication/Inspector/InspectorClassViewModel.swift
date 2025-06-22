import Foundation
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit

public class InspectorClassViewModel: ViewModel<InspectorRoute> {
    @Observed
    private var runtimeClassName: String

    @MemberwiseInit(.public)
    public struct Input {}

    public struct Output {
        public let classHierarchy: Driver<String>
    }

    public func transform(_ input: Input) -> Output {
        return Output(
            classHierarchy: $runtimeClassName.flatMapLatest { [unowned self] runtimeClassName in
                do {
                    return try await appServices.runtimeEngine.runtimeObjectHierarchy(.class(named: runtimeClassName)).joined(separator: "\n")
                } catch {
                    print(error.localizedDescription)
                    return runtimeClassName
                }
            }.catchAndReturn(runtimeClassName).observeOnMainScheduler().asDriverOnErrorJustComplete()
        )
    }

    public init(runtimeClassName: String, appServices: AppServices, router: any Router<InspectorRoute>) {
        self.runtimeClassName = runtimeClassName
        super.init(appServices: appServices, router: router)
    }
}
