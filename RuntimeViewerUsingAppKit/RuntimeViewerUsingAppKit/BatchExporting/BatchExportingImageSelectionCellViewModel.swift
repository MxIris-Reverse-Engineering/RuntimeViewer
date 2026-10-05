import AppKit
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerArchitectures

final class BatchExportingImageSelectionCellViewModel: CellViewModel {
    let image: BatchExportingImage

    /// Whether the image is in the export. The list's ViewModel sets it whenever the selection
    /// changes; the row subscribes to nothing itself, because the list has a row for every image
    /// the engine lists and a subscription per row would build a relay for each of them up front,
    /// on screen or not.
    @RxObserved
    private(set) var isSelected: Bool

    init(image: BatchExportingImage, isSelected: Bool) {
        self.image = image
        self.isSelected = isSelected
        super.init()
    }

    /// Touches the property only when it changes, so a selection change reaches only the rows it
    /// flips.
    func update(isSelected: Bool) {
        if self.isSelected != isSelected {
            self.isSelected = isSelected
        }
    }
}

extension BatchExportingImageSelectionCellViewModel: @MainActor Differentiable {
    var differenceIdentifier: String { image.path }

    func isContentEqual(to source: BatchExportingImageSelectionCellViewModel) -> Bool {
        // Selection isn't part of identity — the cell view drives its
        // checkbox off `$isSelected` directly, so toggling never has to
        // diff the row.
        image == source.image
    }
}
