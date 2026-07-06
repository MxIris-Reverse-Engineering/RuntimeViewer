import Foundation
import RxSwift

extension Observable {
    /// Bridges a value accessed through Apple's Observation framework
    /// (`@Observable`) into a cold `Observable<Element>`.
    ///
    /// On each subscription a `withObservationTracking` chain is installed
    /// that re-arms whenever any property touched inside `access` changes, and
    /// the chain is torn down on dispose so it does not outlive the
    /// subscription. The first value is emitted synchronously at subscription
    /// time.
    ///
    /// `withObservationTracking`'s `onChange` callback fires inside `willSet`,
    /// before the new value is committed — re-reads are therefore deferred to
    /// the next main-queue tick so the observer sees the new value.
    ///
    /// The returned sequence is **cold**: each subscriber installs its own
    /// tracking chain. Pair with `.share(replay: 1, scope: .whileConnected)`
    /// when multiple downstream operators need to observe the same source
    /// without paying for redundant chains.
    ///
    /// - Important: `withObservationTracking` registers **every** `@Observable`
    ///   property read during `access`'s execution, **including reads inside
    ///   nested calls** (initializers, helper functions, computed properties).
    ///   The re-arming chain therefore only reacts to properties `access`
    ///   actually touches — directly or transitively. If a future refactor
    ///   moves the read out of `access`'s reach (e.g. snapshots the value
    ///   beforehand), tracking will silently stop firing. When the dependency
    ///   isn't obvious at the call site, touch it explicitly inside `access`
    ///   (`_ = settings.theme`) so the contract survives refactors.
    public static func tracking(
        _ access: @escaping () -> Element
    ) -> Observable<Element> {
        Observable.create { observer in
            let tracker = ObservationTracker(access: access, observer: observer)
            tracker.start()
            return Disposables.create {
                tracker.cancel.dispose()
            }
        }
    }
}

/// One-subscription state holder for `Observable.tracking`.
///
/// Lives in a class so the re-arming step can run as an instance method —
/// `withObservationTracking`'s `onChange` is `@Sendable`, which would force a
/// nested local function captured by it to also be `@Sendable` (and transitively
/// require every captured value, including non-Sendable Rx primitives, to be
/// Sendable too). Routing through `self` sidesteps that with one
/// `@unchecked Sendable` declaration.
///
/// ### Why `@unchecked Sendable` is safe here
///
/// The `@unchecked` only suppresses the compiler's auto-derivation; the type
/// is still genuinely concurrency-safe. The compiler can't prove it on its own
/// because `AnyObserver` and `BooleanDisposable` ship without `Sendable`
/// conformances, but every field used at runtime is either immutable or
/// internally synchronized:
///
/// - `access` and `observer` are `let` and only read after `init`.
/// - `cancel` is a `let` reference to `BooleanDisposable`, whose `isDisposed`
///   getter and `dispose()` setter are backed by RxSwift's internal `AtomicInt`
///   — safe to touch from any thread without an external lock.
/// - `observe()` re-arms onto `DispatchQueue.main` after the first call, so
///   re-entries are serialized on the main queue regardless of which thread
///   the underlying `@Observable` mutation happens on.
///
/// No mutable instance state exists, so no lock is needed.
private final class ObservationTracker<Element>: @unchecked Sendable {
    private let access: () -> Element
    private let observer: AnyObserver<Element>
    let cancel = BooleanDisposable()

    init(access: @escaping () -> Element, observer: AnyObserver<Element>) {
        self.access = access
        self.observer = observer
    }

    func start() {
        observe()
    }

    private func observe() {
        if cancel.isDisposed { return }
        let value = withObservationTracking {
            access()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.observe()
            }
        }
        observer.onNext(value)
    }
}
