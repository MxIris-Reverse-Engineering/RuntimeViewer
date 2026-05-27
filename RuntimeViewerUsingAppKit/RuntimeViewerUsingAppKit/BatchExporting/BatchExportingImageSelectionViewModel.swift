import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore

final class BatchExportingImageSelectionViewModel: ViewModel<ExportingRoute> {
    struct Input {
        let searchString: Signal<String>
        let selectAllClicked: Signal<Void>
        let deselectAllClicked: Signal<Void>
        let toggleImage: Signal<BatchExportingImage>
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

        input.toggleImage.emitOnNext { [weak self] image in
            guard let self else { return }
            if exportingState.selectedImagePaths.contains(image.path) {
                exportingState.selectedImagePaths.remove(image.path)
            } else {
                exportingState.selectedImagePaths.insert(image.path)
            }
        }
        .disposed(by: rx.disposeBag)

        let filteredDriver = Driver
            .combineLatest(
                exportingState.$availableImages.asDriver(),
                exportingState.$searchString.asDriver()
            )
            .map { [weak self] availableImages, searchString -> [BatchExportingImage] in
                self?.filteredImages(availableImages: availableImages, searchString: searchString) ?? []
            }

        let cellViewModels = Driver
            .combineLatest(filteredDriver, exportingState.$selectedImagePaths.asDriver())
            .map { filtered, selectedPaths -> [BatchExportingImageSelectionCellViewModel] in
                filtered.map {
                    BatchExportingImageSelectionCellViewModel(
                        image: $0,
                        isSelected: selectedPaths.contains($0.path)
                    )
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
