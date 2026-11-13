import Foundation

/// A first-come, first-served async lock for state the whole test process
/// shares. swift-testing runs suites concurrently and `.serialized` only
/// orders the tests inside one suite, so tests in different suites that touch
/// the same process-wide state take one of these instead. Each kind of shared
/// state has its own lock and its own `with…Lock` function saying which tests
/// take it.
actor CrossSuiteTestLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        // Ownership was handed over by `release()` without clearing
        // `isLocked`, so nothing more to do here.
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
