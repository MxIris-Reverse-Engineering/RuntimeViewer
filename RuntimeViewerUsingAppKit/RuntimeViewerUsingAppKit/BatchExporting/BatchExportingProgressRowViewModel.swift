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

    let image: BatchExportingImage

    @RxObserved
    private(set) var status: Status = .queued

    /// Fraction of the current phase that is done. Each phase — every indexing
    /// pass the engine reports, then the interface export — runs its own
    /// 0…1 sweep, so the bar restarts at a phase boundary.
    @RxObserved
    private(set) var progress: Double = 0

    /// What the row is doing right now, shown beside the progress bar while
    /// `status` is `.running`: the indexing phase and its counts, the object
    /// being exported, or the export phase name.
    @RxObserved
    private(set) var progressText: String = ""

    /// Objects whose interface failed during this image's export. Surfaced in the
    /// row tooltip so a partially-failed (but still "succeeded") image isn't silent.
    @RxObserved
    private(set) var objectFailures: [BatchExportingObjectFailure] = []

    init(image: BatchExportingImage) {
        self.image = image
    }

    /// The row leaves the queue. Called before the image is loaded, so the
    /// time spent loading and indexing it counts as work in progress rather
    /// than as waiting.
    func markRunning() {
        status = .running
        progress = 0
        progressText = "Loading image…"
    }

    /// One indexing report from the engine while the image's sections are
    /// built. Phases without a total (a preparation step) only update the
    /// text; the bar keeps its last value rather than snapping to zero.
    func updateIndexingProgress(_ indexingProgress: RuntimeObjectsLoadingProgress) {
        if indexingProgress.totalCount > 0 {
            progress = Double(indexingProgress.currentCount) / Double(indexingProgress.totalCount)
            progressText = "\(indexingProgress.phase.displayDescription) \(indexingProgress.currentCount)/\(indexingProgress.totalCount)"
        } else {
            progressText = indexingProgress.phase.displayDescription
        }
    }

    func updatePhase(_ phaseText: String) {
        progressText = phaseText
    }

    func updateProgress(_ value: Double, text: String) {
        progress = value
        progressText = text
    }

    func markSucceeded(_ result: RuntimeInterfaceExportResult, objectFailures: [BatchExportingObjectFailure] = []) {
        self.objectFailures = objectFailures
        status = .succeeded(result)
        progress = 1
        progressText = ""
    }

    func markFailed(_ description: String) {
        status = .failed(errorDescription: description)
        progressText = ""
    }
}

extension BatchExportingProgressRowViewModel: Differentiable {
    var differenceIdentifier: String { image.path }

    func isContentEqual(to source: BatchExportingProgressRowViewModel) -> Bool {
        true
    }
}
