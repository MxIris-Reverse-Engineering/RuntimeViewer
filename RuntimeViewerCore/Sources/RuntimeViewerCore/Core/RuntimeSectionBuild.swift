import Foundation
import FoundationToolbox

/// One section build that every request for the same image waits on.
///
/// The section factories start one per image and keep it until the finished
/// section is registered; a request that arrives in between waits here instead
/// of building the image a second time. The background indexer and the sidebar
/// routinely ask for the same image at once — opening an image right after
/// launch while an "always index" batch is building it — and a second build
/// costs the whole build again while slowing every other build in the process.
/// Evolution 0002 (background indexing) already required the factories to
/// serialize per path.
///
/// Every request that brings a progress continuation receives the build's
/// progress from the moment it joins, so a sidebar request that joins a
/// background build still drives its progress bar. The build hands its own
/// progress to a relay that fans it out; the relay is drained before the build
/// returns, which keeps the guarantee `RuntimeEngine.pumpingIndexingProgress`
/// makes that no progress event trails the result.
///
/// The build runs in a task of its own, not in the first requester's. Awaiting
/// that task escalates it to the waiter's priority, and the Swift runtime
/// applies the escalation to whichever thread is running it, whatever executor
/// the thread belongs to (the running-task branch of `swift_task_escalate`,
/// `stdlib/public/Concurrency/TaskStatus.cpp`), so a sidebar request that joins
/// a utility-priority background build lifts it to user-initiated. No build
/// path observes cancellation, so a build always ran to completion whoever
/// asked for it; running it apart from its requesters changes nothing there.
final class RuntimeSectionBuild<Section: Sendable>: Sendable {
    private let progressBroadcaster: SectionBuildProgressBroadcaster

    private let task: Task<Section, any Error>

    init(_ build: @escaping @Sendable (LoadingEventContinuation) async throws -> Section) {
        let progressBroadcaster = SectionBuildProgressBroadcaster()
        self.progressBroadcaster = progressBroadcaster
        self.task = Task {
            let (relayStream, relayContinuation) = AsyncThrowingStream<RuntimeObjectsLoadingEvent, any Error>.makeStream()
            let relay = Task {
                for try await event in relayStream {
                    progressBroadcaster.broadcast(event)
                }
            }
            do {
                let section = try await build(relayContinuation)
                relayContinuation.finish()
                _ = await relay.result
                return section
            } catch {
                relayContinuation.finish()
                _ = await relay.result
                throw error
            }
        }
    }

    /// Waits for the section, forwarding the build's progress to
    /// `progressContinuation` from now on. Returns only once every progress
    /// event of the build has been forwarded.
    func section(forwardingProgressTo progressContinuation: LoadingEventContinuation?) async throws -> Section {
        if let progressContinuation {
            progressBroadcaster.add(progressContinuation)
        }
        return try await task.value
    }
}

/// The continuations one section build forwards its progress to.
private final class SectionBuildProgressBroadcaster: Sendable {
    @Mutex
    private var continuations: [LoadingEventContinuation] = []

    func add(_ continuation: LoadingEventContinuation) {
        continuations.append(continuation)
    }

    func broadcast(_ event: RuntimeObjectsLoadingEvent) {
        for continuation in continuations {
            continuation.yield(event)
        }
    }
}
