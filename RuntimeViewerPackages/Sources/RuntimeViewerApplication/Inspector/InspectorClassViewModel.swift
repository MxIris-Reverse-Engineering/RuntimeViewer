import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit

@Loggable(.private)
public final class InspectorClassViewModel: ViewModel<InspectorRuntimeObjectRoute> {
    @Observed
    private var runtimeObject: RuntimeObject

    @MemberwiseInit(.public)
    public struct Input {}

    public struct Output {
        public let classHierarchy: Driver<String>
    }

    public func transform(_ input: Input) -> Output {
        return Output(
            // `weak` + guard, not `unowned`: the async Task outlives disposal
            // (cancellation is cooperative), and the Inspector is rebound on
            // every tab switch / close, so an `unowned self` aborts whenever
            // the fetch is still in flight at deallocation.
            classHierarchy: $runtimeObject.flatMapLatest { [weak self] runtimeObject in
                guard let self else { return runtimeObject.displayName }
                do {
                    return try await documentState.runtimeEngine.hierarchy(for: runtimeObject).joined(separator: "\n")
                } catch {
                    #log(.error, "Failed to fetch class hierarchy for runtime object: \("\(runtimeObject)", privacy: .public) with error: \(error, privacy: .public)")
                    return runtimeObject.displayName
                }
            }.catchAndReturn(runtimeObject.displayName).observeOnMainScheduler().asDriverOnErrorJustComplete()
        )
    }

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<InspectorRuntimeObjectRoute>) {
        self.runtimeObject = runtimeObject
        super.init(documentState: documentState, router: router)
    }
}
