#if os(macOS)

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public final class ExportingProgressViewModel: ViewModel<ExportingRoute> {
    public struct Input {
        public let startExport: Signal<Void>

        public init(startExport: Signal<Void>) {
            self.startExport = startExport
        }
    }

    public struct Output {
        public let phaseText: Driver<String>
        public let progressValue: Driver<Double>
        public let currentObjectText: Driver<String>
    }

    @RxObserved private(set) var phaseText: String = "Preparing..."
    @RxObserved private(set) var progressValue: Double = 0
    @RxObserved private(set) var currentObjectText: String = ""

    private let exportingState: ExportingState

    /// Holds the export without holding this ViewModel, so closing the sheet
    /// releases the ViewModel and stops the export with it.
    private let exportRun = OwnerReportingTask<RuntimeInterfaceExportEvent>()

    public init(exportingState: ExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
    }

    public func transform(_ input: Input) -> Output {
        input.startExport
            .emitOnNext { [weak self] in
                guard let self else { return }
                startExport()
            }
            .disposed(by: rx.disposeBag)
        return Output(
            phaseText: $phaseText.asDriver(),
            progressValue: $progressValue.asDriver(),
            currentObjectText: $currentObjectText.asDriver()
        )
    }

    private var isExporting: Bool = false

    func startExport() {
        if isExporting { return }
        isExporting = true
        guard let directory = exportingState.destinationURL else {
            isExporting = false
            return
        }

        var generationOptions = appDefaults.options
        generationOptions.transformer = settings.transformer

        let configuration = RuntimeInterfaceExportConfiguration(
            imagePath: exportingState.imagePath,
            imageName: exportingState.imageName,
            directory: directory,
            objcFormat: exportingState.objcFormat,
            swiftFormat: exportingState.swiftFormat,
            generationOptions: generationOptions,
            includeMetadata: exportingState.includeMetadata
        )

        let runtimeEngine = documentState.runtimeEngine
        exportRun.start(reportingTo: self) { report in
            let reporter = RuntimeInterfaceExportReporter()
            async let exporting: Void = runtimeEngine.exportInterfaces(with: configuration, reporter: reporter)
            // The reporter finishes its events when the export returns or throws.
            for await event in reporter.events {
                report(event)
            }
            try await exporting
        } receive: { viewModel, event in
            viewModel.handleExportEvent(event)
        } fail: { viewModel, error in
            viewModel.errorRelay.accept(error)
        }
    }

    private func handleExportEvent(_ event: RuntimeInterfaceExportEvent) {
        switch event {
        case .phaseStarted(let phase):
            switch phase {
            case .preparing:
                phaseText = "Preparing..."
                progressValue = 0
                currentObjectText = ""
            case .exporting:
                phaseText = "Exporting interfaces..."
                progressValue = 0
                currentObjectText = ""
            case .writing:
                phaseText = "Writing files..."
            }
        case .phaseCompleted:
            break
        case .phaseFailed(_, let error):
            currentObjectText = error.localizedDescription
        case .objectStarted(let object, let current, let total):
            progressValue = Double(current - 1) / Double(total)
            currentObjectText = "\(object.displayName) (\(current)/\(total))"
        case .objectCompleted:
            break
        case .objectFailed:
            break
        case .completed(let result):
            exportingState.exportResult = result
            progressValue = 1.0
            var parts = ["\(result.succeeded) succeeded"]
            if result.failed > 0 {
                parts.append("\(result.failed) failed")
            }
            parts.append(String(format: "%.1fs", result.totalDuration))
            currentObjectText = parts.joined(separator: " · ")
            router.trigger(.next)
        }
    }
}

extension ExportingProgressViewModel: ExportingStepViewModel {
    public var title: Driver<String> {
        "Exporting..."
    }

    public var isPreviousEnabled: Driver<Bool> {
        false
    }

    public var isNextEnabled: Driver<Bool> {
        false
    }
}

#endif
