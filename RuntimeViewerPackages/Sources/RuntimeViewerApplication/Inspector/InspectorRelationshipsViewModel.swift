import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit

@Loggable(.private)
public final class InspectorRelationshipsViewModel: ViewModel<InspectorRuntimeObjectRoute> {
    /// The list's whole visible state as a single value.
    ///
    /// Loading and rows are one enum rather than two independent drivers on
    /// purpose: the view must never be able to observe "not loading" and the
    /// previous object's subclasses at the same time, which is exactly the
    /// stale-content flash a separate `isLoading` driver would allow.
    public enum RelationshipsState {
        case loading
        case loaded([InspectorRelationshipsCellViewModel])
    }

    /// Raw form of `RelationshipsState` as it leaves the background fetch.
    /// Cell ViewModels build `NSImage`s and `NSAttributedString`s, so they are
    /// only constructed once the pipeline is back on the main scheduler.
    private enum RelationshipsResult {
        case loading
        case loaded([RuntimeObject])
    }

    @RxObserved
    private var runtimeObject: RuntimeObject

    @RxObserved
    public private(set) var state: RelationshipsState = .loading

    @RxObserved
    public private(set) var sectionTitle: String = ""

    @RxObserved
    public private(set) var emptyMessage: String = ""

    @MemberwiseInit(.public)
    public struct Input {
        public let selectRelationshipClicked: Signal<InspectorRelationshipsCellViewModel>
    }

    public struct Output {
        public let state: Driver<RelationshipsState>
        public let sectionTitle: Driver<String>
        public let emptyMessage: Driver<String>
    }

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<InspectorRuntimeObjectRoute>) {
        self.runtimeObject = runtimeObject
        super.init(documentState: documentState, router: router)

        applySectionTexts(for: runtimeObject.kind)

        // Built once in `init` and fed by `update(for:)` rather than rebuilt
        // per inspected object: the view controller binds this ViewModel a
        // single time, so the `tableView.rx.items` adapter survives every
        // selection change instead of being torn down and reinstalled with an
        // empty item list. `flatMapLatest` also drops the in-flight query when
        // the selection moves on — the previous `Task`-based `load()` had no
        // such guard, so a slow cross-image union could land on top of a newer
        // object's results.
        $runtimeObject
            .flatMapLatest { runtimeObject -> Observable<RelationshipsResult> in
                Observable<RelationshipsResult>.async { [weak self] in
                    // `weak` + guard, not `unowned`: the async Task outlives
                    // disposal (cancellation is cooperative), and the
                    // Inspector is torn down on every tab close / engine
                    // swap, so an `unowned self` aborts whenever the query is
                    // still in flight at deallocation.
                    guard let self else { return .loaded([]) }
                    do {
                        let relationships = try await documentState.runtimeEngine.relationships(for: runtimeObject)
                        return .loaded(Self.payload(of: relationships, for: runtimeObject.kind))
                    } catch {
                        #log(.error, "Failed to fetch relationships for runtime object: \("\(runtimeObject)", privacy: .public) with error: \(error, privacy: .public)")
                        await MainActor.run { self.errorRelay.accept(error) }
                        return .loaded([])
                    }
                }
                .withLoadingPlaceholder(
                    .loading,
                    appearsAfter: LoadingPlaceholderTiming.appearsAfter,
                    staysAtLeast: LoadingPlaceholderTiming.staysAtLeast
                )
            }
            .catchAndReturn(.loaded([]))
            .observeOnMainScheduler()
            .map { result -> RelationshipsState in
                switch result {
                case .loading:
                    return .loading
                case .loaded(let relatedObjects):
                    return .loaded(relatedObjects.map(InspectorRelationshipsCellViewModel.init))
                }
            }
            .bind(to: $state)
            .disposed(by: rx.disposeBag)
    }

    /// Point the tab at another object. Re-entering the same object (a `.back`
    /// route from a tab close or a history cursor move) is ignored so the
    /// query is not rerun — and, more importantly, so the placeholder does not
    /// flash for rows that are already on screen.
    public func update(for runtimeObject: RuntimeObject) {
        guard self.runtimeObject != runtimeObject else { return }
        // Applied before the object so the section header is already correct
        // while the placeholder is on screen.
        applySectionTexts(for: runtimeObject.kind)
        self.runtimeObject = runtimeObject
    }

    public func transform(_ input: Input) -> Output {
        input.selectRelationshipClicked.emitOnNext { [weak self] cellViewModel in
            guard let self else { return }
            documentState.selectionRouter.trigger(.push(cellViewModel.runtimeObject))
        }
        .disposed(by: rx.disposeBag)

        return Output(
            state: $state.asDriver(),
            sectionTitle: $sectionTitle.asDriver(),
            emptyMessage: $emptyMessage.asDriver()
        )
    }

    private func applySectionTexts(for kind: RuntimeObjectKind) {
        let sectionTitle = Self.sectionTitle(for: kind)
        self.sectionTitle = sectionTitle
        self.emptyMessage = "No \(sectionTitle.lowercased()) found in indexed images."
    }

    private static func payload(of relationships: RuntimeRelationships, for kind: RuntimeObjectKind) -> [RuntimeObject] {
        switch kind {
        case .objc(.type(.class)),
             .swift(.type(.class)):
            return relationships.subclasses
        case .objc(.type(.protocol)),
             .swift(.type(.protocol)):
            return relationships.conformingTypes
        default:
            return []
        }
    }

    private static func sectionTitle(for kind: RuntimeObjectKind) -> String {
        switch kind {
        case .objc(.type(.class)),
             .swift(.type(.class)):
            return "Subclasses"
        case .objc(.type(.protocol)),
             .swift(.type(.protocol)):
            return "Conforming Types"
        default:
            return ""
        }
    }
}
