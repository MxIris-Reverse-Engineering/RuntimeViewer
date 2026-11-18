#if os(macOS)

import Foundation
import RuntimeViewerArchitectures

public final class BatchExportingCompletionRowViewModel: CellViewModel {
    public let outcome: BatchExportingPerImageOutcome

    public init(outcome: BatchExportingPerImageOutcome) {
        self.outcome = outcome
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension BatchExportingCompletionRowViewModel: Differentiable {
    public var differenceIdentifier: String { outcome.image.path }

    public func isContentEqual(to source: BatchExportingCompletionRowViewModel) -> Bool {
        outcome.image == source.outcome.image
    }
}
#endif

#endif
