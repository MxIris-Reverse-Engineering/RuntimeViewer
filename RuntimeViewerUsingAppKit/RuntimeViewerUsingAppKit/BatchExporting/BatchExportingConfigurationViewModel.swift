import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore

final class BatchExportingConfigurationViewModel: ViewModel<ExportingRoute> {
    struct Input {
        let objcFormatSelected: Signal<Int>
        let swiftFormatSelected: Signal<Int>
        let includeMetadataSelected: Signal<Bool>
    }

    struct Output {
        let summary: Driver<String>
        let objcFormat: Driver<ExportFormat>
        let swiftFormat: Driver<ExportFormat>
        let includeMetadata: Driver<Bool>
    }

    let exportingState: BatchExportingState

    @UserDefault(key: ExportingDefaultsKey.objcFormat, defaultValue: .directory)
    private var storedObjcFormat: ExportFormat

    @UserDefault(key: ExportingDefaultsKey.swiftFormat, defaultValue: .singleFile)
    private var storedSwiftFormat: ExportFormat

    @UserDefault(key: ExportingDefaultsKey.includeMetadata, defaultValue: true)
    private var storedIncludeMetadata: Bool

    init(exportingState: BatchExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
        exportingState.objcFormat = storedObjcFormat
        exportingState.swiftFormat = storedSwiftFormat
        exportingState.includeMetadata = storedIncludeMetadata
    }

    func transform(_ input: Input) -> Output {
        input.objcFormatSelected.emitOnNext { [weak self] index in
            guard let self else { return }
            let format = ExportFormat(rawValue: index) ?? .singleFile
            storedObjcFormat = format
            exportingState.objcFormat = format
        }
        .disposed(by: rx.disposeBag)

        input.swiftFormatSelected.emitOnNext { [weak self] index in
            guard let self else { return }
            let format = ExportFormat(rawValue: index) ?? .singleFile
            storedSwiftFormat = format
            exportingState.swiftFormat = format
        }
        .disposed(by: rx.disposeBag)

        input.includeMetadataSelected.emitOnNext { [weak self] includeMetadata in
            guard let self else { return }
            storedIncludeMetadata = includeMetadata
            exportingState.includeMetadata = includeMetadata
        }
        .disposed(by: rx.disposeBag)

        let summary = exportingState.$selectedImagePaths.asDriver()
            .map { selectedPaths -> String in
                let imageWord = selectedPaths.count == 1 ? "image" : "images"
                return "\(selectedPaths.count) \(imageWord) selected"
            }

        return Output(
            summary: summary,
            objcFormat: exportingState.$objcFormat.asDriver(),
            swiftFormat: exportingState.$swiftFormat.asDriver(),
            includeMetadata: exportingState.$includeMetadata.asDriver()
        )
    }
}

extension BatchExportingConfigurationViewModel: ExportingStepViewModel {
    var title: Driver<String> {
        "Export Configuration:"
    }

    var isPreviousEnabled: Driver<Bool> {
        true
    }

    var isNextEnabled: Driver<Bool> {
        true
    }
}
