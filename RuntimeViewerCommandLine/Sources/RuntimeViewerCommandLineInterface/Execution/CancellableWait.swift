import Foundation

/// Waits for a shared task, passing the caller's cancellation on to it.
///
/// `Task.value` on its own ignores cancellation: the caller stays suspended
/// until the task finishes whatever it is doing, which puts `--timeout` and
/// Ctrl-C out of action for as long as that takes.
///
/// Only for tasks whose result nobody else is waiting on — a client process
/// dialling its host. A task shared across independent callers (the host's
/// engine connection, say) must not be cancelled by whichever one loses
/// patience first: see the comment in `LocalSourceResolver.resolve`.
func awaitCancellably<Success: Sendable>(_ task: Task<Success, any Error>) async throws -> Success {
    try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
