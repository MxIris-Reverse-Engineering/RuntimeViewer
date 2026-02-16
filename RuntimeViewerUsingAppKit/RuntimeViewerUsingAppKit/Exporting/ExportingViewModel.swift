import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingViewModel: ViewModel<MainRoute> {
    enum Page {
        case configuration
        case progress
        case completion
    }

    enum ExportFormat: Int {
        case singleFile = 0
        case directory = 1
    }

    struct Input {
        let cancelClick: Signal<Void>
        let exportClick: Signal<Void>
        let doneClick: Signal<Void>
        let showInFinderClick: Signal<Void>
        let formatSelected: Signal<Int>
    }

    struct Output {
        let currentPage: Driver<Page>
        let imageName: Driver<String>
        let phaseText: Driver<String>
        let progressValue: Driver<Double>
        let currentObjectText: Driver<String>
        let result: Driver<RuntimeInterfaceExportResult?>
        let requestDirectorySelection: Signal<Void>
    }

    @Observed private(set) var currentPage: Page = .configuration
    @Observed private(set) var phaseText: String = ""
    @Observed private(set) var progressValue: Double = 0
    @Observed private(set) var currentObjectText: String = ""
    @Observed private(set) var exportResult: RuntimeInterfaceExportResult?

    private let requestDirectorySelectionRelay = PublishRelay<Void>()

    private var selectedFormat: ExportFormat = .singleFile
    private var exportTask: Task<Void, Never>?
    private var exportedItems: [RuntimeInterfaceExportItem] = []
    private var destinationURL: URL?

    let imagePath: String
    let imageName: String

    init(imagePath: String, imageName: String, documentState: DocumentState, router: any Router<MainRoute>) {
        self.imagePath = imagePath
        self.imageName = imageName
        super.init(documentState: documentState, router: router)
    }

    func transform(_ input: Input) -> Output {
        input.cancelClick.emit(onNext: { [weak self] in
            guard let self else { return }
            exportTask?.cancel()
            router.trigger(.dismiss)
        })
        .disposed(by: rx.disposeBag)

        input.doneClick.emit(onNext: { [weak self] in
            guard let self else { return }
            router.trigger(.dismiss)
        })
        .disposed(by: rx.disposeBag)

        input.showInFinderClick.emit(onNext: { [weak self] in
            guard let self else { return }
            guard let url = destinationURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        .disposed(by: rx.disposeBag)

        input.formatSelected.emit(onNext: { [weak self] index in
            guard let self else { return }
            selectedFormat = ExportFormat(rawValue: index) ?? .singleFile
        })
        .disposed(by: rx.disposeBag)

        input.exportClick.emit(onNext: { [weak self] in
            guard let self else { return }
            requestDirectorySelectionRelay.accept(())
        })
        .disposed(by: rx.disposeBag)

        return Output(
            currentPage: $currentPage.asDriver(),
            imageName: .just(imageName),
            phaseText: $phaseText.asDriver(),
            progressValue: $progressValue.asDriver(),
            currentObjectText: $currentObjectText.asDriver(),
            result: $exportResult.asDriver(),
            requestDirectorySelection: requestDirectorySelectionRelay.asSignal()
        )
    }

    func startExport(to directory: URL) {
        destinationURL = directory
        currentPage = .progress
        phaseText = "Preparing..."
        progressValue = 0

        let reporter = RuntimeInterfaceExportReporter()

        exportTask = Task { [weak self] in
            guard let self else { return }

            let eventTask = Task { [weak self] in
                for await event in reporter.events {
                    guard let self else { return }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.handleExportEvent(event)
                    }
                }
            }

            do {
                let items = try await documentState.runtimeEngine.exportInterfaces(
                    in: imagePath,
                    options: appDefaults.options,
                    reporter: reporter
                )
                self.exportedItems = items
                try self.writeExportedItems(to: directory)
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.errorRelay.accept(error)
                }
            }

            eventTask.cancel()
        }
    }

    private func writeExportedItems(to directory: URL) throws {
        let reporter = RuntimeInterfaceExportReporter()
        switch selectedFormat {
        case .singleFile:
            try RuntimeInterfaceExportWriter.writeSingleFile(
                items: exportedItems,
                to: directory,
                imageName: imageName,
                reporter: reporter
            )
        case .directory:
            try RuntimeInterfaceExportWriter.writeDirectory(
                items: exportedItems,
                to: directory,
                reporter: reporter
            )
        }
    }

    @MainActor
    private func handleExportEvent(_ event: RuntimeInterfaceExportEvent) {
        switch event {
        case .phaseStarted(let phase):
            switch phase {
            case .preparing:
                phaseText = "Preparing..."
            case .exporting:
                phaseText = "Exporting interfaces..."
            case .writing:
                phaseText = "Writing files..."
            }
        case .phaseCompleted:
            break
        case .phaseFailed(_, let error):
            errorRelay.accept(error)
        case .objectStarted(let object, let current, let total):
            progressValue = Double(current) / Double(total)
            currentObjectText = "\(object.displayName) (\(current)/\(total))"
        case .objectCompleted:
            break
        case .objectFailed:
            break
        case .completed(let result):
            exportResult = result
            currentPage = .completion
        }
    }
}
