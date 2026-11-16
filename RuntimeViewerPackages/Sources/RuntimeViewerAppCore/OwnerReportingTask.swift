import Foundation

/// Work whose progress an owner shows — an export a ViewModel's sheet follows.
///
/// The owner holds the task, and the task is cancelled when it goes away, so
/// the work stops with the owner.
@MainActor
public final class OwnerReportingTask<Event> {
    private var task: Task<Void, Never>?

    public init() {}

    deinit {
        task?.cancel()
    }

    /// Starts `work`. Every event it reports is handed to `receive` with the
    /// owner, and an error it throws to `fail`. Starting again cancels the work
    /// started before.
    public func start<Owner: AnyObject>(
        reportingTo owner: Owner,
        work: @escaping @MainActor (_ report: @escaping @MainActor (Event) -> Void) async throws -> Void,
        receive: @escaping @MainActor (Owner, Event) -> Void,
        fail: @escaping @MainActor (Owner, any Error) -> Void = { _, _ in }
    ) {
        task?.cancel()
        task = Task { @MainActor [weak owner] in
            guard let owner else { return }
            do {
                try await work { event in
                    receive(owner, event)
                }
            } catch {
                fail(owner, error)
            }
        }
    }

    /// Stops the work; nothing it reports afterwards reaches the owner.
    public func cancel() {
        task?.cancel()
        task = nil
    }
}
