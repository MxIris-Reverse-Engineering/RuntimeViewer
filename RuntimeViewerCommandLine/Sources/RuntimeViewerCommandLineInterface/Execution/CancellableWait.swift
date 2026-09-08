import Foundation

/// Waits for a task that several callers share, passing the caller's
/// cancellation on to it.
///
/// `Task.value` on its own ignores cancellation: the caller stays suspended
/// until the task finishes whatever it is doing. Anything long enough to be
/// worth sharing — connecting an engine, dialling a host — is therefore long
/// enough to put `--timeout`, and Ctrl-C, out of action.
func awaitCancellably<Success: Sendable>(_ task: Task<Success, any Error>) async throws -> Success {
    try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
