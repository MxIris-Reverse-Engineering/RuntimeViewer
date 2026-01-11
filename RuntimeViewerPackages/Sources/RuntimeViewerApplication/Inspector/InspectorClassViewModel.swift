import Foundation
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit

public final class InspectorClassViewModel: ViewModel<InspectorRoute> {
    @Observed
    private var runtimeObject: RuntimeObject

    @MemberwiseInit(.public)
    public struct Input {}

    public struct Output {
        public let classHierarchy: Driver<String>
    }

    public func transform(_ input: Input) -> Output {
        return Output(
            classHierarchy: $runtimeObject.flatMapLatest { [unowned self] runtimeObject in
                do {
                    return try await appServices.runtimeEngine.hierarchy(for: runtimeObject).joined(separator: "\n")
                } catch {
                    print(error.localizedDescription)
                    return runtimeObject.displayName
                }
            }.catchAndReturn(runtimeObject.displayName).observeOnMainScheduler().asDriverOnErrorJustComplete()
        )
    }

    public init(runtimeObject: RuntimeObject, appServices: AppServices, router: any Router<InspectorRoute>) {
        self.runtimeObject = runtimeObject
        super.init(appServices: appServices, router: router)
    }
}
