import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore
import SwiftUI

final class BatchExportingConfigurationViewModel: ViewModel<ExportingRoute> {
    struct Input {
        let objcFormatSelected: Signal<Int>
        let swiftFormatSelected: Signal<Int>
        let includeMetadataSelected: Signal<Bool>
    }

    struct Output {
        let summary: Driver<String>
        let hasObjC: Driver<Bool>
        let hasSwift: Driver<Bool>
        let objcFormat: Driver<ExportFormat>
        let swiftFormat: Driver<ExportFormat>
        let includeMetadata: Driver<Bool>
    }

    let exportingState: BatchExportingState

    @AppStorage("Exporting.includeMetadata")
    private var storedIncludeMetadata: Bool = true

    @Observed private(set) var isLoading: Bool = true

    override var delayedLoading: Driver<Bool> {
        $isLoading.asDriver()
    }

    init(exportingState: BatchExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
        exportingState.includeMetadata = storedIncludeMetadata
        loadObjects()
    }

    private func loadObjects() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var newObjectsByImage: [String: [RuntimeObject]] = [:]
                for image in exportingState.selectedImages {
                    let objects = try await documentState.runtimeEngine.objects(in: image.path)
                    newObjectsByImage[image.path] = objects
                }
                exportingState.objectsByImage = newObjectsByImage
                isLoading = false
            } catch {
                errorRelay.accept(error)
            }
        }
    }

    func transform(_ input: Input) -> Output {
        input.objcFormatSelected.emitOnNext { [weak self] index in
            guard let self else { return }
            exportingState.objcFormat = ExportFormat(rawValue: index) ?? .singleFile
        }
        .disposed(by: rx.disposeBag)

        input.swiftFormatSelected.emitOnNext { [weak self] index in
            guard let self else { return }
            exportingState.swiftFormat = ExportFormat(rawValue: index) ?? .singleFile
        }
        .disposed(by: rx.disposeBag)

        input.includeMetadataSelected.emitOnNext { [weak self] includeMetadata in
            guard let self else { return }
            storedIncludeMetadata = includeMetadata
            exportingState.includeMetadata = includeMetadata
        }
        .disposed(by: rx.disposeBag)

        let counts = exportingState.$objectsByImage.asDriver()
            .map { dict -> (objcCount: Int, swiftCount: Int) in
                var objcCount = 0
                var swiftCount = 0
                for objects in dict.values {
                    objcCount += objects.count { $0.kind.isObjC }
                    swiftCount += objects.count { $0.kind.isSwift }
                }
                return (objcCount, swiftCount)
            }

        let summary = Driver
            .combineLatest(exportingState.$selectedImagePaths.asDriver(), counts)
            .map { selectedPaths, counts -> String in
                let imageWord = selectedPaths.count == 1 ? "image" : "images"
                var parts = ["\(selectedPaths.count) \(imageWord) selected"]
                if counts.objcCount > 0 { parts.append("\(counts.objcCount) ObjC") }
                if counts.swiftCount > 0 { parts.append("\(counts.swiftCount) Swift") }
                return parts.joined(separator: " · ")
            }

        return Output(
            summary: summary,
            hasObjC: counts.map { $0.objcCount > 0 },
            hasSwift: counts.map { $0.swiftCount > 0 },
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
