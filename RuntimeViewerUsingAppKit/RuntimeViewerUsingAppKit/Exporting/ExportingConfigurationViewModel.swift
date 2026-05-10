import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import SwiftUI

private enum ExportingAppStorageKeys {
    static let includeMetadata = "Exporting.includeMetadata"
}

final class ExportingConfigurationViewModel: ViewModel<ExportingRoute> {
    struct Input {
        let objcFormatSelected: Signal<Int>
        let swiftFormatSelected: Signal<Int>
        let includeMetadataSelected: Signal<Bool>
    }

    struct Output {
        let objcCount: Driver<Int>
        let swiftCount: Driver<Int>
        let hasObjC: Driver<Bool>
        let hasSwift: Driver<Bool>
        let imageName: Driver<String>
        let objcFormat: Driver<ExportFormat>
        let swiftFormat: Driver<ExportFormat>
        let includeMetadata: Driver<Bool>
    }

    let exportingState: ExportingState

    @AppStorage(ExportingAppStorageKeys.includeMetadata)
    private var storedIncludeMetadata: Bool = true

    @Observed private(set) var isLoading: Bool = true

    override var delayedLoading: Driver<Bool> {
        $isLoading.asDriver()
    }

    init(exportingState: ExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
        exportingState.includeMetadata = storedIncludeMetadata
        loadObjects()
    }

    private func loadObjects() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let objects = try await documentState.runtimeEngine.objects(in: exportingState.imagePath)
                exportingState.allObjects = objects
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

        return Output(
            objcCount: exportingState.$allObjects.asDriver().map { $0.count { $0.kind.isObjC } },
            swiftCount: exportingState.$allObjects.asDriver().map { $0.count { $0.kind.isSwift } },
            hasObjC: exportingState.$allObjects.asDriver().map { $0.contains { $0.kind.isObjC } },
            hasSwift: exportingState.$allObjects.asDriver().map { $0.contains { $0.kind.isSwift } },
            imageName: .just(exportingState.imageName),
            objcFormat: exportingState.$objcFormat.asDriver(),
            swiftFormat: exportingState.$swiftFormat.asDriver(),
            includeMetadata: exportingState.$includeMetadata.asDriver()
        )
    }
}

extension ExportingConfigurationViewModel: ExportingStepViewModel {
    var title: Driver<String> {
        "Export Configuration:"
    }

    var isPreviousEnabled: Driver<Bool> {
        false
    }

    var isNextEnabled: Driver<Bool> {
        true
    }
}
