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

        let cellViewModels = Driver
            .combineLatest(
                exportingState.$availableImages.asDriver(),
                exportingState.$searchString.asDriver()
            )
            .map { [weak self] availableImages, searchString -> [BatchExportingImageSelectionCellViewModel] in
                guard let self else { return [] }
                return self.filteredImages(availableImages: availableImages, searchString: searchString).map { image in
                    let isSelected = self.exportingState.$selectedImagePaths
                        .asObservable()
                        .map { [path = image.path] in $0.contains(path) }
                        .distinctUntilChanged()
                    return BatchExportingImageSelectionCellViewModel(image: image, isSelected: isSelected)
                }
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
