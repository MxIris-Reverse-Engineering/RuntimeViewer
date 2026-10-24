import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit

/// The Inspector's Hierarchy page, for a class or for a protocol: a class's
/// superclasses as a chain, a protocol's refined protocols as a tree.
@Loggable(.private)
public final class InspectorHierarchyViewModel: ViewModel<InspectorRuntimeObjectRoute> {
    /// The tab's whole visible state as a single value.
    ///
    /// Loading and content are one enum rather than two independent drivers
    /// on purpose: the view must never be able to observe "not loading" and
    /// "previous object's hierarchy" at the same time, which is exactly the
    /// stale-content flash a separate `isLoading` driver would allow.
    public enum HierarchyState {
        case loading
        /// For a class, the class and then its superclasses, nearest first,
        /// none with levels under it. For a protocol, the protocol alone, with
        /// the protocols it refines under it, and theirs under them.
        case loaded([InspectorHierarchyCellViewModel])
    }

    /// Raw form of `HierarchyState` as it leaves the background fetch. Cell
    /// ViewModels build `NSImage`s and `NSAttributedString`s, so they are only
    /// constructed once the pipeline is back on the main scheduler.
    private enum HierarchyResult {
        case loading
        /// The inspected object and the levels above it: a class's
        /// superclasses, or the protocols a protocol refines.
        case loaded(RuntimeObject, levels: [RuntimeRelationshipNode])
    }

    @RxObserved
    private var runtimeObject: RuntimeObject

    @RxObserved
    public private(set) var hierarchyState: HierarchyState = .loading

    @MemberwiseInit(.public)
    public struct Input {
        public let selectHierarchyLevelClicked: Signal<InspectorHierarchyCellViewModel>
    }

    public struct Output {
        public let hierarchyState: Driver<HierarchyState>
    }

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<InspectorRuntimeObjectRoute>) {
        self.runtimeObject = runtimeObject
        super.init(documentState: documentState, router: router)

        // Built once in `init` and fed by `update(for:)` rather than rebuilt
        // per inspected object: the view controller binds this ViewModel a
        // single time, so the list's adapter survives every selection change.
        // `flatMapLatest` also drops the in-flight fetch when the selection
        // moves on, so a slow result can no longer land on top of a newer one.
        $runtimeObject
            .flatMapLatest { runtimeObject -> Observable<RuntimeObject> in
                // Asked again once the object's image is indexed, as the
                // relationships are; see `InspectorRelationshipsViewModel`.
                let runtimeEngine = MainActor.assumeIsolated { documentState.runtimeEngine }
                return Observable.just(runtimeObject)
                    .concat(runtimeEngine.imageIndexedLater(runtimeObject.imagePath).map { runtimeObject })
            }
            .flatMapLatest { runtimeObject -> Observable<HierarchyResult> in
                // Captures the document-scoped engine (`documentState` is the
                // initializer's parameter here) instead of `self`: the async
                // Task outlives disposal because cancellation is only
                // cooperative, and the Inspector is torn down on every tab
                // close / engine swap, so an `unowned self` would abort
                // whenever a fetch is still in flight at deallocation.
                Observable<HierarchyResult>.async {
                    do {
                        let levels = try await Self.levels(above: runtimeObject, on: documentState.runtimeEngine)
                        return .loaded(runtimeObject, levels: levels)
                    } catch is CancellationError {
                        // The selection moved on, and nothing shows this.
                        return .loaded(runtimeObject, levels: [])
                    } catch {
                        #log(.error, "Failed to fetch the hierarchy of runtime object: \("\(runtimeObject)", privacy: .public) with error: \(error, privacy: .public)")
                        return .loaded(runtimeObject, levels: [])
                    }
                }
                .withLoadingPlaceholder(
                    .loading,
                    appearsAfter: LoadingPlaceholderTiming.appearsAfter,
                    staysAtLeast: LoadingPlaceholderTiming.staysAtLeast
                )
            }
            .catchAndReturn(.loaded(runtimeObject, levels: []))
            .observeOnMainScheduler()
            .map { result -> HierarchyState in
                switch result {
                case .loading:
                    return .loading
                case .loaded(let runtimeObject, let levels):
                    return .loaded(Self.rows(of: runtimeObject, levels: levels))
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
        // The inspected type is already open, and a level no indexed image
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

    /// The rows `HierarchyState.loaded` carries: a class and its superclasses
    /// side by side, or a protocol with the tree of the protocols it refines
    /// under it.
    private static func rows(of runtimeObject: RuntimeObject, levels: [RuntimeRelationshipNode]) -> [InspectorHierarchyCellViewModel] {
        let rootIdentifier = InspectorHierarchyCellViewModel.identifier(of: RuntimeRelationshipNode(object: runtimeObject), at: 0)
        switch runtimeObject.kind {
        case .objc(.type(.protocol)), .swift(.type(.protocol)):
            let children = levels.enumerated().map { index, level in
                InspectorHierarchyCellViewModel(level: level, identifier: InspectorHierarchyCellViewModel.identifier(of: level, at: index, under: rootIdentifier))
            }
            return [InspectorHierarchyCellViewModel(runtimeObject: runtimeObject, children: children, identifier: rootIdentifier)]
        default:
            let superclassRows = levels.enumerated().map { index, level in
                InspectorHierarchyCellViewModel(level: level, identifier: InspectorHierarchyCellViewModel.identifier(of: level, at: index + 1))
            }
            return [InspectorHierarchyCellViewModel(runtimeObject: runtimeObject, identifier: rootIdentifier)] + superclassRows
        }
    }

    /// The levels above `runtimeObject`: the protocols a protocol refines, as
    /// a tree, or a class's superclasses. A peer older than these commands —
    /// an injected payload of an earlier release — has no handler for them;
    /// over a socket it says so in words this build recognises, over XPC it
    /// fails in words of its own, so any failure but a cancellation falls
    /// back. For a class it falls back to the names `hierarchy(for:)` has,
    /// every superclass unresolved; a protocol has nothing to fall back to and
    /// is listed alone.
    private static func levels(above runtimeObject: RuntimeObject, on runtimeEngine: RuntimeEngine) async throws -> [RuntimeRelationshipNode] {
        switch runtimeObject.kind {
        case .objc(.type(.protocol)), .swift(.type(.protocol)):
            do {
                return try await runtimeEngine.refinedProtocolTree(for: runtimeObject)
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                #log(.default, "No refined protocol tree for runtime object: \("\(runtimeObject)", privacy: .public): \(error, privacy: .public)")
                return []
            }
        default:
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
}
