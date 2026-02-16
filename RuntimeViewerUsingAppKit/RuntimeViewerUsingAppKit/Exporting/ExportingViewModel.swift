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
        let progressTotal: Driver<Int>
        let currentObjectText: Driver<String>
        let result: Driver<RuntimeInterfaceExportResult?>
        let requestDirectorySelection: Signal<Void>
    }

    private let currentPageRelay = BehaviorRelay<Page>(value: .configuration)
    private let phaseTextRelay = BehaviorRelay<String>(value: "")
    private let progressValueRelay = BehaviorRelay<Double>(value: 0)
    private let progressTotalRelay = BehaviorRelay<Int>(value: 0)
    private let currentObjectTextRelay = BehaviorRelay<String>(value: "")
    private let resultRelay = BehaviorRelay<RuntimeInterfaceExportResult?>(value: nil)
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
        input.cancelClick
            .emit(onNext: { [weak self] in
                guard let self else { return }
                exportTask?.cancel()
                router.trigger(.dismiss)
            })
            .disposed(by: rx.disposeBag)

        input.doneClick
            .emit(onNext: { [weak self] in
                guard let self else { return }
                router.trigger(.dismiss)
            })
            .disposed(by: rx.disposeBag)

        input.showInFinderClick
            .emit(onNext: { [weak self] in
                guard let self, let url = destinationURL else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
            .disposed(by: rx.disposeBag)

        input.formatSelected
            .emit(onNext: { [weak self] index in
                self?.selectedFormat = ExportFormat(rawValue: index) ?? .singleFile
            })
            .disposed(by: rx.disposeBag)

        input.exportClick
            .emit(onNext: { [weak self] in
                self?.requestDirectorySelectionRelay.accept(())
            })
            .disposed(by: rx.disposeBag)

        return Output(
            currentPage: currentPageRelay.asDriver(),
            imageName: .just(imageName),
            phaseText: phaseTextRelay.asDriver(),
            progressValue: progressValueRelay.asDriver(),
            progressTotal: progressTotalRelay.asDriver(),
            currentObjectText: currentObjectTextRelay.asDriver(),
            result: resultRelay.asDriver(),
            requestDirectorySelection: requestDirectorySelectionRelay.asSignal()
        )
    }

    func startExport(to directory: URL) {
        destinationURL = directory
        currentPageRelay.accept(.progress)
        phaseTextRelay.accept("Preparing...")
        progressValueRelay.accept(0)

        let reporter = RuntimeInterfaceExportReporter()

        // Observe events on a background-safe manner, relay to main thread
        exportTask = Task { [weak self] in
            guard let self else { return }

            // Start consuming events in a child task
            let eventTask = Task { [weak self] in
                for await event in reporter.events {
                    guard let self else { return }
                    await MainActor.run {
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

                // Write files
                try self.writeExportedItems(to: directory)
            } catch {
                await MainActor.run {
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
                phaseTextRelay.accept("Preparing...")
            case .exporting:
                phaseTextRelay.accept("Exporting interfaces...")
            case .writing:
                phaseTextRelay.accept("Writing files...")
            }
        case .phaseCompleted:
            break
        case .phaseFailed(_, let error):
            errorRelay.accept(error)
        case .objectStarted(let object, let current, let total):
            progressTotalRelay.accept(total)
            progressValueRelay.accept(Double(current) / Double(total))
            currentObjectTextRelay.accept("\(object.displayName) (\(current)/\(total))")
        case .objectCompleted:
            break
        case .objectFailed:
            break
        case .completed(let result):
            resultRelay.accept(result)
            currentPageRelay.accept(.completion)
        }
    }
}
