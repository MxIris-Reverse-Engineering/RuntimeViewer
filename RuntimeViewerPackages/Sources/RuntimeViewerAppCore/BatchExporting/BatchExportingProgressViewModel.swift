#if os(macOS)

import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettings

public final class BatchExportingProgressViewModel: ViewModel<ExportingRoute> {
    public struct Input {
        public let startExport: Signal<Void>

        public init(startExport: Signal<Void>) {
            self.startExport = startExport
        }
    }

    public struct Output {
        public let titleText: Driver<String>
        public let progressText: Driver<String>
        public let overallProgress: Driver<Double>
        public let rows: Driver<[BatchExportingProgressRowViewModel]>
    }

    @RxObserved private(set) var titleText: String = ""
    @RxObserved private(set) var progressText: String = ""
    @RxObserved private(set) var overallProgress: Double = 0

    private let exportingState: BatchExportingState

    /// What the export loop reports back to this ViewModel.
    private enum ExportProgress {
        case imageFinished(BatchExportingPerImageOutcome)
        case allImagesFinished
    }

    /// Holds the export loop without holding this ViewModel, so closing the
    /// sheet releases the ViewModel and stops the export with it.
    private let exportRun = OwnerReportingTask<ExportProgress>()

    public init(exportingState: BatchExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
    }

    public func transform(_ input: Input) -> Output {
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

        let images = exportingState.selectedImages
        guard !images.isEmpty else {
            isExporting = false
            return
        }

        // Taken as they are when the export starts.
        let generationOptionsByImagePath = Self.generationOptionsByImagePath(
            for: images,
            generationOptions: settings.generationOptions,
            transformer: settings.transformer,
            in: documentState.runtimeEngine
        )

        let total = images.count
        // Locals, so the export loop below captures them and not this view model.
        let documentState = self.documentState
        let runtimeEngine = documentState.runtimeEngine
        let objcFormat = exportingState.objcFormat
        let swiftFormat = exportingState.swiftFormat
        let cPlusPlusFormat = exportingState.cPlusPlusFormat
        let includeMetadata = exportingState.includeMetadata
        let concurrency = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))

        let rowViewModels = images.map { BatchExportingProgressRowViewModel(image: $0) }
        exportingState.progressRowViewModels = rowViewModels

        titleText = "Exporting \(total) image\(total == 1 ? "" : "s")…"
        progressText = "0 / \(total) completed"
        overallProgress = 0

        exportingState.perImageOutcomes = []
        exportRun.start(reportingTo: self) { report in
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
                            cPlusPlusFormat: cPlusPlusFormat,
                            includeMetadata: includeMetadata,
                            generationOptions: generationOptionsByImagePath[rowViewModel.image.path] ?? RuntimeObjectInterface.GenerationOptions(),
                            runtimeEngine: runtimeEngine,
                            documentState: documentState,
                        )
                    }
                }

                while let outcome = await group.next() {
                    report(.imageFinished(outcome))

                    // A cancelled export starts no further image.
                    if !Task.isCancelled, let nextRowViewModel = iterator.next() {
                        group.addTask { @MainActor in
                            await Self.exportOne(
                                rowViewModel: nextRowViewModel,
                                baseDirectory: directory,
                                objcFormat: objcFormat,
                                swiftFormat: swiftFormat,
                                cPlusPlusFormat: cPlusPlusFormat,
                                includeMetadata: includeMetadata,
                                generationOptions: generationOptionsByImagePath[nextRowViewModel.image.path] ?? RuntimeObjectInterface.GenerationOptions(),
                                runtimeEngine: runtimeEngine,
                                documentState: documentState,
                            )
                        }
                    }
                }
            }

            report(.allImagesFinished)
        } receive: { viewModel, progress in
            viewModel.handle(progress, total: total)
        }
    }

    private func handle(_ progress: ExportProgress, total: Int) {
        switch progress {
        case .imageFinished(let outcome):
            exportingState.perImageOutcomes.append(outcome)
            let completedCount = exportingState.perImageOutcomes.count
            let succeededCount = exportingState.perImageOutcomes.count(where: \.didSucceed)
            let failedCount = completedCount - succeededCount
            overallProgress = Double(completedCount) / Double(total)
            var parts = ["\(completedCount) / \(total) completed"]
            if succeededCount > 0 { parts.append("\(succeededCount) succeeded") }
            if failedCount > 0 { parts.append("\(failedCount) failed") }
            progressText = parts.joined(separator: " · ")
        case .allImagesFinished:
            overallProgress = 1
            titleText = "Completed \(total) image\(total == 1 ? "" : "s")"
            exportingState.aggregatedResult = .init(outcomes: exportingState.perImageOutcomes)
            router.trigger(.next)
        }
    }

    @MainActor
    /// The options each image exports with: its own effective Generation Options, as the content
    /// pane shows it (proposal `generation-options-image-overrides`), with the transformer.
    static func generationOptionsByImagePath(
        for images: [BatchExportingImage],
        generationOptions: Settings.GenerationOptionsSettings,
        transformer: Transformer.Configuration,
        in runtimeEngine: RuntimeEngine
    ) -> [String: RuntimeObjectInterface.GenerationOptions] {
        Dictionary(
            images.map { image -> (String, RuntimeObjectInterface.GenerationOptions) in
                var imageGenerationOptions = generationOptions.effectiveOptions(forImageAt: image.path, in: runtimeEngine)
                imageGenerationOptions.transformer = transformer
                return (image.path, imageGenerationOptions)
            },
            uniquingKeysWith: { firstOptions, _ in firstOptions }
        )
    }

    private static func exportOne(
        rowViewModel: BatchExportingProgressRowViewModel,
        baseDirectory: URL,
        objcFormat: ExportFormat,
        swiftFormat: ExportFormat,
        cPlusPlusFormat: ExportFormat,
        includeMetadata: Bool,
        generationOptions: RuntimeObjectInterface.GenerationOptions,
        runtimeEngine: RuntimeEngine,
        documentState: DocumentState,
    ) async -> BatchExportingPerImageOutcome {
        let image = rowViewModel.image

        // Running starts here, not after the load: loading an image also
        // indexes it, and for a large framework that index is the longest
        // step of the whole export. Keyed on "indexed" rather than "loaded"
        // because an image dyld pulled in as a dependency is loaded but has
        // no sections yet, and the export needs the sections either way.
        rowViewModel.markRunning()
        do {
            // The user's own load: Manual Loading lists it, and it counts as work in progress,
            // which keeps the app out of App Nap while the export runs in the background.
            try await documentState.indexImageForUser(at: image.path) { indexingProgress in
                await MainActor.run {
                    rowViewModel.updateIndexingProgress(indexingProgress)
                }
            }
        } catch {
            let description = error.localizedDescription
            rowViewModel.markFailed(description)
            return .init(image: image, outcome: .failure(errorDescription: description))
        }

        rowViewModel.updateProgress(0, text: "Preparing…")

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
            cPlusPlusFormat: cPlusPlusFormat,
            generationOptions: generationOptions,
            includeMetadata: includeMetadata,
            includesCPlusPlusObjects: true,
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
                        text: "\(object.displayName) (\(current)/\(totalObjects))",
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
