#if os(macOS)

import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore

public final class BatchExportingConfigurationViewModel: ViewModel<ExportingRoute> {
    public struct Input {
        public let objcFormatSelected: Signal<Int>
        public let swiftFormatSelected: Signal<Int>
        public let cPlusPlusFormatSelected: Signal<Int>
        public let includeMetadataSelected: Signal<Bool>

        public init(objcFormatSelected: Signal<Int>, swiftFormatSelected: Signal<Int>, cPlusPlusFormatSelected: Signal<Int>, includeMetadataSelected: Signal<Bool>) {
            self.objcFormatSelected = objcFormatSelected
            self.swiftFormatSelected = swiftFormatSelected
            self.cPlusPlusFormatSelected = cPlusPlusFormatSelected
            self.includeMetadataSelected = includeMetadataSelected
        }
    }

    public struct Output {
        public let summary: Driver<String>
        public let objcFormat: Driver<ExportFormat>
        public let swiftFormat: Driver<ExportFormat>
        public let cPlusPlusFormat: Driver<ExportFormat>
        public let includeMetadata: Driver<Bool>
    }

    public let exportingState: BatchExportingState

    @UserDefault(key: ExportingDefaultsKey.objcFormat, defaultValue: .directory)
    private var storedObjcFormat: ExportFormat

    @UserDefault(key: ExportingDefaultsKey.swiftFormat, defaultValue: .singleFile)
    private var storedSwiftFormat: ExportFormat

    @UserDefault(key: ExportingDefaultsKey.cPlusPlusFormat, defaultValue: .directory)
    private var storedCPlusPlusFormat: ExportFormat

    @UserDefault(key: ExportingDefaultsKey.includeMetadata, defaultValue: true)
    private var storedIncludeMetadata: Bool

    public init(exportingState: BatchExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
        exportingState.objcFormat = storedObjcFormat
        exportingState.swiftFormat = storedSwiftFormat
        exportingState.cPlusPlusFormat = storedCPlusPlusFormat
        exportingState.includeMetadata = storedIncludeMetadata
    }

    public func transform(_ input: Input) -> Output {
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

        input.cPlusPlusFormatSelected.emitOnNext { [weak self] index in
            guard let self else { return }
            let format = ExportFormat(rawValue: index) ?? .directory
            storedCPlusPlusFormat = format
            exportingState.cPlusPlusFormat = format
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
            cPlusPlusFormat: exportingState.$cPlusPlusFormat.asDriver(),
            includeMetadata: exportingState.$includeMetadata.asDriver()
        )
    }
}

extension BatchExportingConfigurationViewModel: ExportingStepViewModel {
    public var title: Driver<String> {
        "Export Configuration:"
    }

    public var isPreviousEnabled: Driver<Bool> {
        true
    }

    public var isNextEnabled: Driver<Bool> {
        true
    }
}

#endif
