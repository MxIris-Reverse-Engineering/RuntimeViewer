import Foundation

/// Work whose progress an owner shows — an export a ViewModel's sheet follows —
/// run so that it never keeps the owner alive.
///
/// The work holds no reference to the owner: it reports events, and each one
/// reaches the owner only while the owner is still there and the work has not
/// been cancelled. The owner holds the task, so when the owner goes away — its
/// sheet was closed — the task goes with it and cancels the work. A task that
/// held its owner instead kept it alive for as long as the work ran: the
/// owner's own cancellation never ran, a closed export sheet went on writing
/// files, and what the owner did once the work finished ran after its
/// coordinator was gone.
@MainActor
public final class OwnerReportingTask<Event> {
    /// The owner, reached only between the work's suspensions.
    @MainActor
    private final class OwnerReference<Owner: AnyObject> {
        weak var owner: Owner?

        init(_ owner: Owner) {
            self.owner = owner
        }
    }

    private var task: Task<Void, Never>?

    public init() {}

    deinit {
        task?.cancel()
    }

    /// Starts `work`. Every event it reports is handed to `receive` with the
    /// owner, and an error it throws to `fail` — neither once the owner is gone
    /// or the work is cancelled, and `fail` never for the cancellation itself.
    /// Starting again cancels the work started before.
    ///
    /// `work` must not capture the owner: what it needs of the owner it takes
    /// before it starts, and what it has to tell the owner it reports.
    public func start<Owner: AnyObject>(
        reportingTo owner: Owner,
        work: @escaping @MainActor (_ report: @escaping @MainActor (Event) -> Void) async throws -> Void,
        receive: @escaping @MainActor (Owner, Event) -> Void,
        fail: @escaping @MainActor (Owner, any Error) -> Void = { _, _ in }
    ) {
        task?.cancel()
        let ownerReference = OwnerReference(owner)
        task = Task { @MainActor in
            do {
                try await work { event in
                    guard !Task.isCancelled, let owner = ownerReference.owner else { return }
                    receive(owner, event)
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let owner = ownerReference.owner else { return }
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
