import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerCore

final class BatchExportingProgressRowViewModel: NSObject, @unchecked Sendable {
    enum Status: Sendable {
        case queued
        case running
        case succeeded(RuntimeInterfaceExportResult)
        case failed(errorDescription: String)
    }

    let image: BatchExportingImage

    @Observed
    private(set) var status: Status = .queued

    @Observed
    private(set) var progress: Double = 0

    @Observed
    private(set) var currentObjectText: String = ""

    init(image: BatchExportingImage) {
        self.image = image
    }

    func markRunning() {
        status = .running
        progress = 0
        currentObjectText = "Preparing…"
    }

    func updatePhase(_ phaseText: String) {
        currentObjectText = phaseText
    }

    func updateProgress(_ value: Double, currentObject: String) {
        progress = value
        currentObjectText = currentObject
    }

    func markSucceeded(_ result: RuntimeInterfaceExportResult) {
        status = .succeeded(result)
        progress = 1
        currentObjectText = ""
    }

    func markFailed(_ description: String) {
        status = .failed(errorDescription: description)
        currentObjectText = ""
    }
}

extension BatchExportingProgressRowViewModel: Differentiable {
    var differenceIdentifier: String { image.path }

    func isContentEqual(to source: BatchExportingProgressRowViewModel) -> Bool {
        true
    }
}
