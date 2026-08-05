import Foundation
import RxSwift

extension ObservableType {
    /// Prefix slow work with a placeholder element — but only once the work
    /// turns out to actually be slow, and once the placeholder is showing,
    /// keep it showing long enough to be read as a placeholder rather than as
    /// a blink.
    ///
    /// - Work that finishes within `appearsAfter` emits only its result, so a
    ///   fast fetch swaps content in place with no intermediate state at all.
    /// - Work that runs past `appearsAfter` emits `placeholderElement` first,
    ///   and its result is then held back until the placeholder has been up
    ///   for `staysAtLeast` — measured from when it appeared, so a genuinely
    ///   slow fetch adds no delay of its own.
    ///
    /// Both halves exist to stop the placeholder from *becoming* the flicker
    /// it was meant to hide: without the delay every warm cache lookup flashes
    /// one, and without the minimum duration any fetch landing just past the
    /// delay flashes one for a single frame.
    public func withLoadingPlaceholder(
        _ placeholderElement: Element,
        appearsAfter: TimeInterval,
        staysAtLeast: TimeInterval,
        scheduler: SchedulerType = MainScheduler.instance
    ) -> Observable<Element> {
        Observable.deferred {
            let placeholderAppearance = LoadingPlaceholderAppearance()

            // Shared so the upstream work is subscribed exactly once: the
            // placeholder's `take(until:)` below subscribes to it as well.
            let work = self.asObservable()
                .flatMap { element -> Observable<Element> in
                    let remainingTime = placeholderAppearance.remainingTime(ofMinimumDuration: staysAtLeast)
                    guard remainingTime > 0 else { return .just(element) }
                    return Observable.just(element).delay(.milliseconds(Int(remainingTime * 1000)), scheduler: scheduler)
                }
                .share(replay: 1, scope: .whileConnected)

            let placeholder = Observable.just(placeholderElement)
                .delay(.milliseconds(Int(appearsAfter * 1000)), scheduler: scheduler)
                .do(onNext: { _ in placeholderAppearance.markAppeared() })
                .take(until: work)

            return Observable.merge(placeholder, work)
        }
    }
}

/// Records when the placeholder became visible, so the result is held back by
/// the remainder of the minimum duration rather than by the whole of it again.
private final class LoadingPlaceholderAppearance {
    private var appearedAt: Date?

    func markAppeared() {
        appearedAt = Date()
    }

    func remainingTime(ofMinimumDuration minimumDuration: TimeInterval) -> TimeInterval {
        guard let appearedAt else { return 0 }
        return max(0, minimumDuration - Date().timeIntervalSince(appearedAt))
    }
}
