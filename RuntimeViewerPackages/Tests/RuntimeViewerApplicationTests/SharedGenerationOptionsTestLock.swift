import Foundation

/// Cross-suite mutual exclusion for the Generation Options every
/// `AppDefaults` in the process shares.
///
/// `AppDefaults.options` is a `@UserDefault` on `UserDefaults.standard`,
/// whatever directory an isolated instance keeps its files in, and its
/// projected value is a key-value observation of that one key — so a write
/// from any test reaches every live subscriber in every suite. A Find session
/// takes such a write for the user changing the options and runs its search
/// again, which turns "the results were merged into, not replaced" into a
/// race with whichever suite toggled the options last.
///
/// Wrap both kinds of test in `withSharedGenerationOptionsLock`:
/// - tests that WRITE `appDefaults.options`, and
/// - tests whose assertions an options change would invalidate.
private let sharedGenerationOptionsTestLock = CrossSuiteTestLock()

func withSharedGenerationOptionsLock<Result>(_ body: () async throws -> Result) async rethrows -> Result {
    await sharedGenerationOptionsTestLock.acquire()
    defer {
        Task {
            await sharedGenerationOptionsTestLock.release()
        }
    }
    return try await body()
}
