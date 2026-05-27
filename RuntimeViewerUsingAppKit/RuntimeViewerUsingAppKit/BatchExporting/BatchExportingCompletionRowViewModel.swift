import AppKit
import RuntimeViewerArchitectures

final class BatchExportingCompletionRowViewModel: NSObject, @unchecked Sendable {
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
