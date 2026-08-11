import Dependencies
import Foundation

/// Runs `operation` with the live dependency context.
///
/// swift-dependencies defaults to `.test` inside a test target, which
/// makes every `@Dependency` without an explicit `testValue` trap. View
/// models under test resolve `\.settings` / `\.appDefaults` eagerly, so
/// they must be constructed here.
func withLiveDependencyContext<Result>(_ operation: () throws -> Result) rethrows -> Result {
    try withDependencies {
        $0.context = .live
    } operation: {
        try operation()
    }
}

/// Polls `condition` until it holds or `timeout` elapses.
///
/// Returns whether the condition was met, so the call site can `#expect`
/// on it with a message rather than failing on a bare timeout.
func pollUntil(
    timeout: Duration,
    _ condition: () async throws -> Bool
) async rethrows -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return false
}
