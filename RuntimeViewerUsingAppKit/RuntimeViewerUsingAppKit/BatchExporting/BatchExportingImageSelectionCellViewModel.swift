import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerCore

final class BatchExportingImageSelectionCellViewModel: NSObject, @unchecked Sendable {
    let image: BatchExportingImage

    @Observed
    private(set) var isSelected: Bool = false

    private let disposeBag = DisposeBag()

    init(image: BatchExportingImage, isSelected: Observable<Bool>) {
        self.image = image
        super.init()
        isSelected
            .bind(to: $isSelected)
            .disposed(by: disposeBag)
    }
}

extension BatchExportingImageSelectionCellViewModel: Differentiable {
    var differenceIdentifier: String { image.path }

    func isContentEqual(to source: BatchExportingImageSelectionCellViewModel) -> Bool {
        // Selection isn't part of identity — the cell view drives its
        // checkbox off `$isSelected` directly, so toggling never has to
        // diff the row.
        image == source.image
    }
}
