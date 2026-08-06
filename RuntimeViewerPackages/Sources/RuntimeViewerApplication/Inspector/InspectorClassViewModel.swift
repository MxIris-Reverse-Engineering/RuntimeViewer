import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit

@Loggable(.private)
public final class InspectorClassViewModel: ViewModel<InspectorRuntimeObjectRoute> {
    /// The tab's whole visible state as a single value.
    ///
    /// Loading and content are one enum rather than two independent drivers
    /// on purpose: the view must never be able to observe "not loading" and
    /// "previous object's hierarchy" at the same time, which is exactly the
    /// stale-content flash a separate `isLoading` driver would allow.
    public enum HierarchyState: Equatable {
        case loading
        case loaded(String)
    }

    @Observed
    private var runtimeObject: RuntimeObject

    @Observed
    public private(set) var hierarchyState: HierarchyState = .loading

    @MemberwiseInit(.public)
    public struct Input {}

    public struct Output {
        public let hierarchyState: Driver<HierarchyState>
    }

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<InspectorRuntimeObjectRoute>) {
        self.runtimeObject = runtimeObject
        super.init(documentState: documentState, router: router)

        // Built once in `init` and fed by `update(for:)` rather than rebuilt
        // per inspected object: the view controller binds this ViewModel a
        // single time, so `tableView.rx.items` / label bindings survive every
        // selection change. `flatMapLatest` also drops the in-flight fetch
        // when the selection moves on, so a slow result can no longer land on
        // top of a newer one.
        $runtimeObject
            .flatMapLatest { runtimeObject -> Observable<HierarchyState> in
                // Captures the document-scoped engine (`documentState` is the
                // initializer's parameter here) instead of `self`: the async
                // Task outlives disposal because cancellation is only
                // cooperative, and the Inspector is torn down on every tab
                // close / engine swap, so an `unowned self` would abort
                // whenever a fetch is still in flight at deallocation.
                Observable<HierarchyState>.async {
                    do {
                        let hierarchy = try await documentState.runtimeEngine.hierarchy(for: runtimeObject)
                        return .loaded(hierarchy.joined(separator: "\n"))
                    } catch {
                        #log(.error, "Failed to fetch class hierarchy for runtime object: \("\(runtimeObject)", privacy: .public) with error: \(error, privacy: .public)")
                        return .loaded(runtimeObject.displayName)
                    }
                }
                .withLoadingPlaceholder(
                    .loading,
                    appearsAfter: LoadingPlaceholderTiming.appearsAfter,
                    staysAtLeast: LoadingPlaceholderTiming.staysAtLeast
                )
            }
            .catchAndReturn(.loaded(runtimeObject.displayName))
            .observeOnMainScheduler()
            .bind(to: $hierarchyState)
            .disposed(by: rx.disposeBag)
    }

    /// Point the tab at another object. Re-entering the same object (a `.back`
    /// route from a tab close or a history cursor move) is ignored so the
    /// hierarchy is not refetched — and, more importantly, so the placeholder
    /// does not flash for content that is already on screen.
    public func update(for runtimeObject: RuntimeObject) {
        guard self.runtimeObject != runtimeObject else { return }
        self.runtimeObject = runtimeObject
    }

    public func transform(_ input: Input) -> Output {
        Output(hierarchyState: $hierarchyState.asDriver())
    }
}
