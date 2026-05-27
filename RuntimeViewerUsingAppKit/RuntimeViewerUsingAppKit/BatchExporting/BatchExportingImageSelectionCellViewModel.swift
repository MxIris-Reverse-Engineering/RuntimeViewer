import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerCore

final class BatchExportingImageSelectionCellViewModel: NSObject, @unchecked Sendable {
    let image: BatchExportingImage
    let isSelected: Bool

    init(image: BatchExportingImage, isSelected: Bool) {
        self.image = image
        self.isSelected = isSelected
    }
}

extension BatchExportingImageSelectionCellViewModel: Differentiable {
    var differenceIdentifier: String { image.path }

    func isContentEqual(to source: BatchExportingImageSelectionCellViewModel) -> Bool {
        image == source.image && isSelected == source.isSelected
    }
}
