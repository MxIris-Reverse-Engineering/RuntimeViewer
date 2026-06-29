import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerCore

/// View model behind the sidebar scope popover. Edits a working `draft`
/// copy of the scope and pushes every change back through the relay handed
/// in by the sidebar view model, so the sidebar list narrows live as the
/// user clicks. There is no Apply / Cancel split — closing the popover just
/// dismisses the UI; whatever state the relay holds at dismissal time is
/// the new active scope.
final class SidebarRuntimeObjectScopeViewModel<Route: Routable>: ViewModel<Route> {
    private let relay: BehaviorRelay<RuntimeObjectScope>

    @Observed private(set) var draft: RuntimeObjectScope

    /// Snapshot of which kinds appear in the current image. The popover
    /// uses this to hide rows for kinds nothing carries; the model itself
    /// stays agnostic.
    let availableKinds: Set<RuntimeObjectKind>

    /// Snapshot of which `RuntimeObject.Properties` bits actually occur in
    /// the current image. Drives row visibility in the Properties section.
    let availableProperties: RuntimeObject.Properties

    init(
        relay: BehaviorRelay<RuntimeObjectScope>,
        availableKinds: Set<RuntimeObjectKind>,
        availableProperties: RuntimeObject.Properties,
        documentState: DocumentState,
        router: any Router<Route>
    ) {
        self.relay = relay
        self.draft = relay.value
        self.availableKinds = availableKinds
        self.availableProperties = availableProperties
        super.init(documentState: documentState, router: router)
    }

    struct Input {
        let toggleKind: Signal<RuntimeObjectKind>
        let toggleGroup: Signal<RuntimeObjectScope.KindGroup>
        let setGeneric: Signal<RuntimeObjectScope.PropertyState>
        let setSpecialized: Signal<RuntimeObjectScope.PropertyState>
        let reset: Signal<Void>
    }

    struct Output {
        let draft: Driver<RuntimeObjectScope>
    }

    func transform(_ input: Input) -> Output {
        input.toggleKind.emitOnNext { [weak self] kind in
            guard let self else { return }
            var next = draft
            next.toggleKind(kind)
            commit(next)
        }
        .disposed(by: rx.disposeBag)

        input.toggleGroup.emitOnNext { [weak self] group in
            guard let self else { return }
            var next = draft
            next.toggleGroup(group)
            commit(next)
        }
        .disposed(by: rx.disposeBag)

        input.setGeneric.emitOnNext { [weak self] state in
            guard let self else { return }
            var next = draft
            next.generic = state
            commit(next)
        }
        .disposed(by: rx.disposeBag)

        input.setSpecialized.emitOnNext { [weak self] state in
            guard let self else { return }
            var next = draft
            next.specialized = state
            commit(next)
        }
        .disposed(by: rx.disposeBag)

        input.reset.emitOnNext { [weak self] in
            guard let self else { return }
            commit(.init())
        }
        .disposed(by: rx.disposeBag)

        return Output(draft: $draft.asDriver())
    }

    private func commit(_ next: RuntimeObjectScope) {
        guard next != draft else { return }
        draft = next
        relay.accept(next)
    }
}
