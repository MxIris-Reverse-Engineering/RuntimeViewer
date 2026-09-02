import Foundation
import RxSwift

/// Thrown when the sequence completes before delivering the awaited element.
struct SequenceCompletedWithoutValue: Error {}

/// Thrown when the awaited element does not arrive within the timeout.
struct AwaitTimeout: Error, CustomStringConvertible {
    let seconds: TimeInterval

    var description: String { "no matching element arrived within \(seconds)s" }
}

/// Resumes a continuation at most once, whichever Rx callback fires first and
/// on whichever thread it fires.
private final class SingleResumption<Value> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Waits for the first element of `source` that satisfies `predicate`.
///
/// Main-actor bound because `Driver` / `Signal` sources assert that they are
/// subscribed on the main thread.
@MainActor
func nextValue<Source: ObservableConvertibleType>(
    from source: Source,
    timeout: TimeInterval = 10,
    where predicate: @escaping (Source.Element) -> Bool = { _ in true }
) async throws -> Source.Element {
    let disposeBag = DisposeBag()
    return try await withCheckedThrowingContinuation { continuation in
        let resumption = SingleResumption(continuation)
        source.asObservable()
            .filter(predicate)
            .take(1)
            .timeout(
                .milliseconds(Int(timeout * 1000)),
                other: Observable.error(AwaitTimeout(seconds: timeout)),
                scheduler: MainScheduler.instance
            )
            .subscribe(
                onNext: { resumption.resume(with: .success($0)) },
                onError: { resumption.resume(with: .failure($0)) },
                onCompleted: { resumption.resume(with: .failure(SequenceCompletedWithoutValue())) }
            )
            .disposed(by: disposeBag)
    }
}

/// Collects every element `source` emits during `interval`, then returns them.
/// Use it to prove that nothing was emitted, which `nextValue` cannot express.
@MainActor
func values<Source: ObservableConvertibleType>(
    from source: Source,
    during interval: TimeInterval
) async throws -> [Source.Element] {
    let disposeBag = DisposeBag()
    return try await withCheckedThrowingContinuation { continuation in
        let resumption = SingleResumption(continuation)
        source.asObservable()
            .take(for: .milliseconds(Int(interval * 1000)), scheduler: MainScheduler.instance)
            .toArray()
            .subscribe(
                onSuccess: { resumption.resume(with: .success($0)) },
                onFailure: { resumption.resume(with: .failure($0)) }
            )
            .disposed(by: disposeBag)
    }
}

/// Lets the main queue drain the synchronous Rx work a relay emission kicked
/// off (Signal handlers, `observeOnMainScheduler` hops) before asserting.
@MainActor
func settleMainQueue() async throws {
    try await Task.sleep(for: .milliseconds(50))
}
