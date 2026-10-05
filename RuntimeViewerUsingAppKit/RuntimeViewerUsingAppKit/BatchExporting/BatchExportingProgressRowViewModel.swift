import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore

final class BatchExportingProgressRowViewModel: CellViewModel {
    enum Status: Sendable {
        case queued
        case running
        case succeeded(RuntimeInterfaceExportResult)
        case failed(errorDescription: String)
    }

    /// Everything the row shows, in one stream. A batch holds a row per selected image — every
    /// image the engine lists, after Select All — and every `@RxObserved` a cell binds costs a
    /// relay with a lock of its own for as long as the row exists (proposal
    /// 0005-cellvm-appearance-single-observed).
    struct State {
        var status: Status = .queued

        /// Fraction of the current phase that is done. Each phase — every indexing
        /// pass the engine reports, then the interface export — runs its own
        /// 0…1 sweep, so the bar restarts at a phase boundary.
        var progress: Double = 0

        /// What the row is doing right now, shown beside the progress bar while
        /// `status` is `.running`: the indexing phase and its counts, the object
        /// being exported, or the export phase name.
        var progressText: String = ""

        /// Objects whose interface failed during this image's export. Surfaced in the
        /// row tooltip so a partially-failed (but still "succeeded") image isn't silent.
        var objectFailures: [BatchExportingObjectFailure] = []
    }

    let image: BatchExportingImage

    @RxObserved
    private(set) var state: State = State()

    init(image: BatchExportingImage) {
        self.image = image
    }

    /// The row leaves the queue. Called before the image is loaded, so the
    /// time spent loading and indexing it counts as work in progress rather
    /// than as waiting.
    func markRunning() {
        updateState { newState in
            newState.status = .running
            newState.progress = 0
            newState.progressText = "Loading image…"
        }
    }

    /// One indexing report from the engine while the image's sections are
    /// built. Phases without a total (a preparation step) only update the
    /// text; the bar keeps its last value rather than snapping to zero.
    func updateIndexingProgress(_ indexingProgress: RuntimeObjectsLoadingProgress) {
        updateState { newState in
            if indexingProgress.totalCount > 0 {
                newState.progress = Double(indexingProgress.currentCount) / Double(indexingProgress.totalCount)
                newState.progressText = "\(indexingProgress.phase.displayDescription) \(indexingProgress.currentCount)/\(indexingProgress.totalCount)"
            } else {
                newState.progressText = indexingProgress.phase.displayDescription
            }
        }
    }

    func updatePhase(_ phaseText: String) {
        updateState { newState in
            newState.progressText = phaseText
        }
    }

    func updateProgress(_ value: Double, text: String) {
        updateState { newState in
            newState.progress = value
            newState.progressText = text
        }
    }

    func markSucceeded(_ result: RuntimeInterfaceExportResult, objectFailures: [BatchExportingObjectFailure] = []) {
        updateState { newState in
            newState.objectFailures = objectFailures
            newState.status = .succeeded(result)
            newState.progress = 1
            newState.progressText = ""
        }
    }

    func markFailed(_ description: String) {
        updateState { newState in
            newState.status = .failed(errorDescription: description)
            newState.progressText = ""
        }
    }

    /// Applies a transition to a copy and publishes it in one assignment. `@RxObserved` sends an
    /// event for every assignment, so setting the fields one by one would redraw the cell once
    /// per field.
    private func updateState(_ transition: (inout State) -> Void) {
        var newState = state
        transition(&newState)
        state = newState
    }
}

extension BatchExportingProgressRowViewModel: Differentiable {
    var differenceIdentifier: String { image.path }

    func isContentEqual(to source: BatchExportingProgressRowViewModel) -> Bool {
        true
    }
}
