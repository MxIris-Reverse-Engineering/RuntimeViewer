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
                    return try await documentState.runtimeEngine.hierarchy(for: runtimeObject).joined(separator: "\n")
                } catch {
                    logger.error("Failed to fetch class hierarchy for runtime object: \("\(runtimeObject)", privacy: .public) with error: \(error, privacy: .public)")
                    return runtimeObject.displayName
                }
            }.catchAndReturn(runtimeObject.displayName).observeOnMainScheduler().asDriverOnErrorJustComplete()
        )
    }

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<InspectorRoute>) {
        self.runtimeObject = runtimeObject
        super.init(documentState: documentState, router: router)
    }
}
