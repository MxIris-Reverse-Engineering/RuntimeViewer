import Foundation

/// When a settings editor writes the value it edits back to the settings: a
/// moment after the editing stops, as one write instead of one per keystroke
/// or per frame of a colour drag (KnownIssues TS.1), and at once when the
/// user commits.
@MainActor
public final class DraftWriteBack<Value> {
    private struct PendingWrite {
        let value: Value
        let write: @MainActor (Value) -> Void
        let task: Task<Void, Never>
    }

    private let delay: Duration

    private var pendingWrite: PendingWrite?

    public init(delay: Duration) {
        self.delay = delay
    }

    /// The draft changed: `value` is written with `write` once `delay` has
    /// passed without another change, replacing a write still waiting.
    public func draftDidChange(to value: Value, write: @escaping @MainActor (Value) -> Void) {
        pendingWrite?.task.cancel()
        let delay = delay
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            pendingWrite = nil
            write(value)
        }
        pendingWrite = PendingWrite(value: value, write: write, task: task)
    }

    /// The user committed `value`: it is written now, and a write still
    /// waiting is dropped.
    public func commit(_ value: Value, write: @MainActor (Value) -> Void) {
        pendingWrite?.task.cancel()
        pendingWrite = nil
        write(value)
    }

    /// The editor went away.
    public func editorDidDisappear() {
        pendingWrite?.task.cancel()
        pendingWrite = nil
    }
}
