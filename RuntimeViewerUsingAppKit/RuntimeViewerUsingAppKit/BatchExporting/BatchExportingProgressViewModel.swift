import AppKit
import Foundation
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore

final class BatchExportingProgressViewModel: ViewModel<ExportingRoute> {
    struct Input {
        let startExport: Signal<Void>
    }

    struct Output {
        let titleText: Driver<String>
        let progressText: Driver<String>
        let overallProgress: Driver<Double>
        let rows: Driver<[BatchExportingProgressRowViewModel]>
    }

    @Observed private(set) var titleText: String = ""
    @Observed private(set) var progressText: String = ""
    @Observed private(set) var overallProgress: Double = 0

    private let exportingState: BatchExportingState
    private var exportTask: Task<Void, Never>?

    init(exportingState: BatchExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
    }

    deinit {
        exportTask?.cancel()
    }

    func transform(_ input: Input) -> Output {
        input.startExport.emitOnNext { [weak self] in
            guard let self else { return }
            startExport()
        }
        .disposed(by: rx.disposeBag)

        return Output(
            titleText: $titleText.asDriver(),
            progressText: $progressText.asDriver(),
            overallProgress: $overallProgress.asDriver(),
            rows: exportingState.$progressRowViewModels.asDriver(),
        )
    }

    private var isExporting = false

    private func startExport() {
        guard !isExporting else { return }
        isExporting = true
        guard let directory = exportingState.destinationURL else {
            isExporting = false
            return
        }

        var generationOptions = appDefaults.options
        generationOptions.transformer = settings.transformer

        let images = exportingState.selectedImages
        guard !images.isEmpty else {
            isExporting = false
            return
        }

        let total = images.count
        let runtimeEngine = documentState.runtimeEngine
        let objcFormat = exportingState.objcFormat
        let swiftFormat = exportingState.swiftFormat
        let includeMetadata = exportingState.includeMetadata
        let concurrency = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))

        let rowViewModels = images.map { BatchExportingProgressRowViewModel(image: $0) }
        exportingState.progressRowViewModels = rowViewModels

        titleText = "Exporting \(total) image\(total == 1 ? "" : "s")…"
        progressText = "0 / \(total) completed"
        overallProgress = 0

        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            exportingState.perImageOutcomes = []
            var succeededCount = 0
            var failedCount = 0
            var completedCount = 0

            await withTaskGroup(of: BatchExportingPerImageOutcome.self) { group in
                var iterator = rowViewModels.makeIterator()

                for _ in 0 ..< concurrency {
                    guard let rowViewModel = iterator.next() else { break }
                    group.addTask { @MainActor in
                        await Self.exportOne(
                            rowViewModel: rowViewModel,
                            baseDirectory: directory,
                            objcFormat: objcFormat,
                            swiftFormat: swiftFormat,
                            includeMetadata: includeMetadata,
                            generationOptions: generationOptions,
                            runtimeEngine: runtimeEngine,
                        )
                    }
                }

                while let outcome = await group.next() {
                    completedCount += 1
                    if outcome.didSucceed {
                        succeededCount += 1
                    } else {
                        failedCount += 1
                    }
                    self.exportingState.perImageOutcomes.append(outcome)
                    self.overallProgress = Double(completedCount) / Double(total)
                    var parts = ["\(completedCount) / \(total) completed"]
                    if succeededCount > 0 { parts.append("\(succeededCount) succeeded") }
                    if failedCount > 0 { parts.append("\(failedCount) failed") }
                    self.progressText = parts.joined(separator: " · ")

                    if let nextRowViewModel = iterator.next() {
                        group.addTask { @MainActor in
                            await Self.exportOne(
                                rowViewModel: nextRowViewModel,
                                baseDirectory: directory,
                                objcFormat: objcFormat,
                                swiftFormat: swiftFormat,
                                includeMetadata: includeMetadata,
                                generationOptions: generationOptions,
                                runtimeEngine: runtimeEngine,
                            )
                        }
                    }
                }
            }

            overallProgress = 1
            titleText = "Completed \(total) image\(total == 1 ? "" : "s")"
            exportingState.aggregatedResult = .init(outcomes: exportingState.perImageOutcomes)
            router.trigger(.next)
        }
    }

    @MainActor
    private static func exportOne(
        rowViewModel: BatchExportingProgressRowViewModel,
        baseDirectory: URL,
        objcFormat: ExportFormat,
        swiftFormat: ExportFormat,
        includeMetadata: Bool,
        generationOptions: RuntimeObjectInterface.GenerationOptions,
        runtimeEngine: RuntimeEngine,
    ) async -> BatchExportingPerImageOutcome {
        let image = rowViewModel.image

        do {
            if try await !runtimeEngine.isImageLoaded(path: image.path) {
                try await runtimeEngine.loadImage(at: image.path)
            }
        } catch {
            let description = error.localizedDescription
            rowViewModel.markFailed(description)
            return .init(image: image, outcome: .failure(errorDescription: description))
        }

        rowViewModel.markRunning()

        let sanitizedName = sanitize(image.name)
        let perImageDirectory = baseDirectory.appendingPathComponent(sanitizedName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: perImageDirectory, withIntermediateDirectories: true)
        } catch {
            let description = error.localizedDescription
            rowViewModel.markFailed(description)
            return .init(image: image, outcome: .failure(errorDescription: description))
        }

        let configuration = RuntimeInterfaceExportConfiguration(
            imagePath: image.path,
            imageName: sanitizedName,
            directory: perImageDirectory,
            objcFormat: objcFormat,
            swiftFormat: swiftFormat,
            generationOptions: generationOptions,
            includeMetadata: includeMetadata,
        )

        let reporter = RuntimeInterfaceExportReporter()
        let eventsTask: Task<(result: RuntimeInterfaceExportResult?, failures: [BatchExportingObjectFailure]), Never> = Task { @MainActor in
            var capturedResult: RuntimeInterfaceExportResult?
            var objectFailures: [BatchExportingObjectFailure] = []
            for await event in reporter.events {
                switch event {
                case .phaseStarted(let phase):
                    switch phase {
                    case .preparing:
                        rowViewModel.updatePhase("Preparing…")
                    case .exporting:
                        rowViewModel.updatePhase("Exporting interfaces…")
                    case .writing:
                        rowViewModel.updatePhase("Writing files…")
                    }
                case .objectStarted(let object, let current, let totalObjects):
                    rowViewModel.updateProgress(
                        Double(current - 1) / Double(totalObjects),
                        currentObject: "\(object.displayName) (\(current)/\(totalObjects))",
                    )
                case .objectFailed(let object, let error):
                    objectFailures.append(
                        BatchExportingObjectFailure(
                            objectName: object.displayName,
                            errorDescription: error.localizedDescription,
                        )
                    )
                case .completed(let result):
                    capturedResult = result
                default:
                    break
                }
            }
            return (capturedResult, objectFailures)
        }

        do {
            try await runtimeEngine.exportInterfaces(with: configuration, reporter: reporter)
            let captured = await eventsTask.value
            if let result = captured.result {
                rowViewModel.markSucceeded(result, objectFailures: captured.failures)
                return .init(image: image, outcome: .success(result), objectFailures: captured.failures)
            } else {
                let description = "No completion event received"
                rowViewModel.markFailed(description)
                return .init(image: image, outcome: .failure(errorDescription: description))
            }
        } catch {
            eventsTask.cancel()
            _ = await eventsTask.value
            let description = error.localizedDescription
            rowViewModel.markFailed(description)
            return .init(image: image, outcome: .failure(errorDescription: description))
        }
    }

    private static func sanitize(_ name: String) -> String {
        let unsafe: Set<Character> = ["/", ":", "\\", "*", "?", "\"", "<", ">", "|"]
        let cleaned = String(name.map { unsafe.contains($0) ? "_" : $0 })
        return cleaned.isEmpty ? "Unnamed" : cleaned
    }
}

extension BatchExportingProgressViewModel: ExportingStepViewModel {
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
