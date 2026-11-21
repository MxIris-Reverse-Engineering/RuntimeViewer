#if os(macOS)

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public final class ExportingConfigurationViewModel: ViewModel<ExportingRoute> {
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
        public let objcCount: Driver<Int>
        public let swiftCount: Driver<Int>
        /// The C++ classes and namespaces the export writes, nested ones
        /// included: one file each in the directory format.
        public let cPlusPlusCount: Driver<Int>
        public let hasObjC: Driver<Bool>
        public let hasSwift: Driver<Bool>
        public let hasCPlusPlus: Driver<Bool>
        public let imageName: Driver<String>
        public let objcFormat: Driver<ExportFormat>
        public let swiftFormat: Driver<ExportFormat>
        public let cPlusPlusFormat: Driver<ExportFormat>
        public let includeMetadata: Driver<Bool>
    }

    public let exportingState: ExportingState

    @UserDefault(key: ExportingDefaultsKey.objcFormat, defaultValue: .directory)
    private var storedObjcFormat: ExportFormat

    @UserDefault(key: ExportingDefaultsKey.swiftFormat, defaultValue: .singleFile)
    private var storedSwiftFormat: ExportFormat

    @UserDefault(key: ExportingDefaultsKey.cPlusPlusFormat, defaultValue: .directory)
    private var storedCPlusPlusFormat: ExportFormat

    @UserDefault(key: ExportingDefaultsKey.includeMetadata, defaultValue: true)
    private var storedIncludeMetadata: Bool

    @RxObserved private(set) var isLoading: Bool = true

    public override var delayedLoading: Driver<Bool> {
        $isLoading.asDriver()
    }

    public init(exportingState: ExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
        exportingState.objcFormat = storedObjcFormat
        exportingState.swiftFormat = storedSwiftFormat
        exportingState.cPlusPlusFormat = storedCPlusPlusFormat
        exportingState.includeMetadata = storedIncludeMetadata
        loadObjects()
    }

    private func loadObjects() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // The export asks for the image's C++ objects too
                // (proposal `cplusplus-export`), so the page counts them.
                let objects = try await documentState.runtimeEngine.objects(in: exportingState.imagePath, includesCPlusPlusObjects: true)
                exportingState.allObjects = objects
                isLoading = false
            } catch {
                errorRelay.accept(error)
            }
        }
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

        return Output(
            objcCount: exportingState.$allObjects.asDriver().map { $0.count { $0.kind.isObjC } },
            swiftCount: exportingState.$allObjects.asDriver().map { $0.count { $0.kind.isSwift } },
            cPlusPlusCount: exportingState.$allObjects.asDriver().map { $0.flatMap(\.exportedObjects).count { $0.kind.isCPlusPlus } },
            hasObjC: exportingState.$allObjects.asDriver().map { $0.contains { $0.kind.isObjC } },
            hasSwift: exportingState.$allObjects.asDriver().map { $0.contains { $0.kind.isSwift } },
            hasCPlusPlus: exportingState.$allObjects.asDriver().map { $0.contains { $0.kind.isCPlusPlus } },
            imageName: .just(exportingState.imageName),
            objcFormat: exportingState.$objcFormat.asDriver(),
            swiftFormat: exportingState.$swiftFormat.asDriver(),
            cPlusPlusFormat: exportingState.$cPlusPlusFormat.asDriver(),
            includeMetadata: exportingState.$includeMetadata.asDriver()
        )
    }
}

extension ExportingConfigurationViewModel: ExportingStepViewModel {
    public var title: Driver<String> {
        "Export Configuration:"
    }

    public var isPreviousEnabled: Driver<Bool> {
        false
    }

    public var isNextEnabled: Driver<Bool> {
        true
    }
}

#endif
