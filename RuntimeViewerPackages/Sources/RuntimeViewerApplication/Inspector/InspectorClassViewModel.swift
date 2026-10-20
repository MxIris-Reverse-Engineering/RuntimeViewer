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
    public enum HierarchyState {
        case loading
        /// The inspected class, then its superclasses, nearest first.
        case loaded([InspectorClassHierarchyCellViewModel])
    }

    /// Raw form of `HierarchyState` as it leaves the background fetch. Cell
    /// ViewModels build `NSImage`s and `NSAttributedString`s, so they are only
    /// constructed once the pipeline is back on the main scheduler.
    private enum HierarchyResult {
        case loading
        case loaded(RuntimeObject, superclasses: [RuntimeRelationshipNode])
    }

    @RxObserved
    private var runtimeObject: RuntimeObject

    @RxObserved
    public private(set) var hierarchyState: HierarchyState = .loading

    @MemberwiseInit(.public)
    public struct Input {
        public let selectHierarchyLevelClicked: Signal<InspectorClassHierarchyCellViewModel>
    }

    public struct Output {
        public let hierarchyState: Driver<HierarchyState>
    }

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<InspectorRuntimeObjectRoute>) {
        self.runtimeObject = runtimeObject
        super.init(documentState: documentState, router: router)

        // Built once in `init` and fed by `update(for:)` rather than rebuilt
        // per inspected object: the view controller binds this ViewModel a
        // single time, so the `tableView.rx.items` adapter survives every
        // selection change. `flatMapLatest` also drops the in-flight fetch
        // when the selection moves on, so a slow result can no longer land on
        // top of a newer one.
        $runtimeObject
            .flatMapLatest { runtimeObject -> Observable<HierarchyResult> in
                // Captures the document-scoped engine (`documentState` is the
                // initializer's parameter here) instead of `self`: the async
                // Task outlives disposal because cancellation is only
                // cooperative, and the Inspector is torn down on every tab
                // close / engine swap, so an `unowned self` would abort
                // whenever a fetch is still in flight at deallocation.
                Observable<HierarchyResult>.async {
                    do {
                        let superclasses = try await Self.superclassChain(of: runtimeObject, on: documentState.runtimeEngine)
                        return .loaded(runtimeObject, superclasses: superclasses)
                    } catch {
                        #log(.error, "Failed to fetch class hierarchy for runtime object: \("\(runtimeObject)", privacy: .public) with error: \(error, privacy: .public)")
                        return .loaded(runtimeObject, superclasses: [])
                    }
                }
                .withLoadingPlaceholder(
                    .loading,
                    appearsAfter: LoadingPlaceholderTiming.appearsAfter,
                    staysAtLeast: LoadingPlaceholderTiming.staysAtLeast
                )
            }
            .catchAndReturn(.loaded(runtimeObject, superclasses: []))
            .observeOnMainScheduler()
            .map { result -> HierarchyState in
                switch result {
                case .loading:
                    return .loading
                case .loaded(let runtimeObject, let superclasses):
                    return .loaded(
                        [InspectorClassHierarchyCellViewModel(runtimeObject: runtimeObject)]
                            + superclasses.map(InspectorClassHierarchyCellViewModel.init(level:))
                    )
                }
            }
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
        // The inspected class is already open, and a level no indexed image
        // defines has nothing to open.
        input.selectHierarchyLevelClicked.emitOnNext { [weak self] cellViewModel in
            guard let self,
                  let levelObject = cellViewModel.runtimeObject,
                  levelObject != runtimeObject
            else { return }
            documentState.selectionRouter.trigger(.push(levelObject))
        }
        .disposed(by: rx.disposeBag)

        return Output(hierarchyState: $hierarchyState.asDriver())
    }

    /// `runtimeObject`'s superclasses. A peer older than the superclass chain
    /// command — an injected payload of an earlier release — has no handler
    /// for it; over a socket it says so in words this build recognises, over
    /// XPC it fails in words of its own. What it does have is
    /// `hierarchy(for:)`, which names the class and its superclasses, so any
    /// failure but a cancellation falls back to those names, every level
    /// unresolved.
    private static func superclassChain(of runtimeObject: RuntimeObject, on runtimeEngine: RuntimeEngine) async throws -> [RuntimeRelationshipNode] {
        do {
            return try await runtimeEngine.superclassChain(for: runtimeObject)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            #log(.default, "No superclass chain for runtime object: \("\(runtimeObject)", privacy: .public), falling back to the names: \(error, privacy: .public)")
            let names = try await runtimeEngine.hierarchy(for: runtimeObject)
            // The names start with the class itself.
            return names.dropFirst().map { RuntimeRelationshipNode(name: $0, object: nil, children: []) }
        }
    }
}
