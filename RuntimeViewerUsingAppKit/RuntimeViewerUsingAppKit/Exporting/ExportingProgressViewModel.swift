import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingProgressViewModel: ViewModel<ExportingRoute> {
    struct Input {
        let startExport: Signal<Void>
    }

    struct Output {
        let phaseText: Driver<String>
        let progressValue: Driver<Double>
        let currentObjectText: Driver<String>
    }

    @Observed private(set) var phaseText: String = "Preparing..."
    @Observed private(set) var progressValue: Double = 0
    @Observed private(set) var currentObjectText: String = ""

    private let exportingState: ExportingState

    private var exportTask: Task<Void, Never>?

    init(exportingState: ExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
    }

    func transform(_ input: Input) -> Output {
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
        guard let directory = exportingState.destinationURL else { return }

        var generationOptions = appDefaults.options
        generationOptions.transformer = settings.transformer

        let configuration = RuntimeInterfaceExportConfiguration(
            imagePath: exportingState.imagePath,
            imageName: exportingState.imageName,
            directory: directory,
            objcFormat: exportingState.objcFormat,
            swiftFormat: exportingState.swiftFormat,
            generationOptions: generationOptions
        )

        let reporter = RuntimeInterfaceExportReporter()

        Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in reporter.events {
                handleExportEvent(event)
            }
        }

        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await documentState.runtimeEngine.exportInterfaces(
                    with: configuration,
                    reporter: reporter
                )
            } catch {
                errorRelay.accept(error)
            }
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
    var title: Driver<String> {
        "Exporting..."
    }

    var isPreviousEnabled: Driver<Bool> {
        false
    }

    var isNextEnabled: Driver<Bool> {
        false
    }
}
