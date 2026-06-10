import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures

final class BatchExportingCompletionRowViewModel: CellViewModel {
    let outcome: BatchExportingPerImageOutcome

    init(outcome: BatchExportingPerImageOutcome) {
        self.outcome = outcome
    }
}

extension BatchExportingCompletionRowViewModel: Differentiable {
    var differenceIdentifier: String { outcome.image.path }

    func isContentEqual(to source: BatchExportingCompletionRowViewModel) -> Bool {
        outcome.image == source.outcome.image
    }
}
