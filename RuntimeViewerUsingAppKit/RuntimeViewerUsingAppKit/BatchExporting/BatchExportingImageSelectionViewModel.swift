import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore

final class BatchExportingImageSelectionViewModel: ViewModel<ExportingRoute> {
    struct Input {
        let searchString: Signal<String>
        let selectAllClicked: Signal<Void>
        let deselectAllClicked: Signal<Void>
        let toggleImage: Signal<BatchExportingImageSelectionCellViewModel>
    }

    struct Output {
        let cellViewModels: Driver<[BatchExportingImageSelectionCellViewModel]>
        let selectionSummary: Driver<String>
    }

    let exportingState: BatchExportingState

    /// Every row built so far, reused by each search: typing into the search field filters these
    /// instead of building a row per image again.
    private var cellViewModelsByImage: [BatchExportingImage: BatchExportingImageSelectionCellViewModel] = [:]

    init(exportingState: BatchExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
    }

    func transform(_ input: Input) -> Output {
        input.searchString.emitOnNext { [weak self] string in
            guard let self else { return }
            exportingState.searchString = string
        }
        .disposed(by: rx.disposeBag)

        input.selectAllClicked.emitOnNext { [weak self] in
            guard let self else { return }
            let visiblePaths = filteredImages(
                availableImages: exportingState.availableImages,
                searchString: exportingState.searchString
            ).map(\.path)
            exportingState.selectedImagePaths.formUnion(visiblePaths)
        }
        .disposed(by: rx.disposeBag)

        input.deselectAllClicked.emitOnNext { [weak self] in
            guard let self else { return }
            let visiblePaths = filteredImages(
                availableImages: exportingState.availableImages,
                searchString: exportingState.searchString
            ).map(\.path)
            exportingState.selectedImagePaths.subtract(visiblePaths)
        }
        .disposed(by: rx.disposeBag)

        input.toggleImage.emitOnNext { [weak self] cellViewModel in
            guard let self else { return }
            let path = cellViewModel.image.path
            if exportingState.selectedImagePaths.contains(path) {
                exportingState.selectedImagePaths.remove(path)
            } else {
                exportingState.selectedImagePaths.insert(path)
            }
        }
        .disposed(by: rx.disposeBag)

        // The rows subscribe to nothing themselves; the selection is pushed into them from here.
        exportingState.$selectedImagePaths.asDriver().driveOnNext { [weak self] selectedImagePaths in
            guard let self else { return }
            for cellViewModel in cellViewModelsByImage.values {
                cellViewModel.update(isSelected: selectedImagePaths.contains(cellViewModel.image.path))
            }
        }
        .disposed(by: rx.disposeBag)

        let cellViewModels = Driver
            .combineLatest(
                exportingState.$availableImages.asDriver(),
                exportingState.$searchString.asDriver()
            )
            .map { [weak self] availableImages, searchString -> [BatchExportingImageSelectionCellViewModel] in
                guard let self else { return [] }
                return self.filteredImages(availableImages: availableImages, searchString: searchString).map(self.cellViewModel(for:))
            }

        let selectionSummary = Driver
            .combineLatest(
                exportingState.$selectedImagePaths.asDriver(),
                exportingState.$availableImages.asDriver()
            )
            .map { selected, available -> String in
                "\(selected.count) of \(available.count) selected"
            }

        return Output(cellViewModels: cellViewModels, selectionSummary: selectionSummary)
    }

    private func filteredImages(availableImages: [BatchExportingImage], searchString: String) -> [BatchExportingImage] {
        let trimmed = searchString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return availableImages }
        return availableImages.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private func cellViewModel(for image: BatchExportingImage) -> BatchExportingImageSelectionCellViewModel {
        if let cellViewModel = cellViewModelsByImage[image] {
            return cellViewModel
        }
        let cellViewModel = BatchExportingImageSelectionCellViewModel(
            image: image,
            isSelected: exportingState.selectedImagePaths.contains(image.path)
        )
        cellViewModelsByImage[image] = cellViewModel
        return cellViewModel
    }
}

extension BatchExportingImageSelectionViewModel: ExportingStepViewModel {
    var title: Driver<String> {
        "Select Images:"
    }

    var previousTitle: Driver<String> {
        "Previous"
    }

    var nextTitle: Driver<String> {
        "Next"
    }

    var isPreviousEnabled: Driver<Bool> {
        false
    }

    var isNextEnabled: Driver<Bool> {
        exportingState.$selectedImagePaths.asDriver().map { !$0.isEmpty }
    }
}
