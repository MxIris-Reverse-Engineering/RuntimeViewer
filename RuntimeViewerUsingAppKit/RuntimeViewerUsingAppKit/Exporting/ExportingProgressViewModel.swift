import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingProgressViewModel: ViewModel<MainRoute> {
    enum Page {
        case progress
        case completion
    }

    struct ExportResult {
        let succeeded: Int
        let failed: Int
        let totalDuration: TimeInterval
        let objcCount: Int
        let swiftCount: Int
    }

    struct Input {
        let cancelClick: Signal<Void>
        let doneClick: Signal<Void>
        let showInFinderClick: Signal<Void>
    }

    struct Output {
        let currentPage: Driver<Page>
        let phaseText: Driver<String>
        let progressValue: Driver<Double>
        let currentObjectText: Driver<String>
        let result: Driver<ExportResult?>
    }

    @Observed private(set) var currentPage: Page = .progress
    @Observed private(set) var phaseText: String = "Preparing..."
    @Observed private(set) var progressValue: Double = 0
    @Observed private(set) var currentObjectText: String = ""
    @Observed private(set) var exportResult: ExportResult?

    private let exportingState: ExportingState
    private var exportTask: Task<Void, Never>?

    init(exportingState: ExportingState, documentState: DocumentState, router: any Router<MainRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
    }

    func transform(_ input: Input) -> Output {
        input.cancelClick.emitOnNext { [weak self] in
            guard let self else { return }
            exportTask?.cancel()
            router.trigger(.dismiss)
        }
        .disposed(by: rx.disposeBag)

        input.doneClick.emitOnNext { [weak self] in
            guard let self else { return }
            router.trigger(.dismiss)
        }
        .disposed(by: rx.disposeBag)

        input.showInFinderClick.emitOnNext { [weak self] in
            guard let self else { return }
            guard let url = exportingState.destinationURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .disposed(by: rx.disposeBag)

        return Output(
            currentPage: $currentPage.asDriver(),
            phaseText: $phaseText.asDriver(),
            progressValue: $progressValue.asDriver(),
            currentObjectText: $currentObjectText.asDriver(),
            result: $exportResult.asDriver()
        )
    }

    func startExport() {
        guard let directory = exportingState.destinationURL else { return }

        currentPage = .progress
        phaseText = "Exporting interfaces..."
        progressValue = 0
        currentObjectText = ""
        exportResult = nil

        let selectedObjcObjects = exportingState.selectedObjcObjects
        let selectedSwiftObjects = exportingState.selectedSwiftObjects
        let allSelected = selectedObjcObjects + selectedSwiftObjects

        exportTask = Task { [weak self] in
            guard let self else { return }

            let startTime = CFAbsoluteTimeGetCurrent()
            var items: [RuntimeInterfaceExportItem] = []
            var succeeded = 0
            var failed = 0

            do {
                for (index, object) in allSelected.enumerated() {
                    if Task.isCancelled { break }

                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        progressValue = Double(index) / Double(allSelected.count)
                        currentObjectText = "\(object.displayName) (\(index + 1)/\(allSelected.count))"
                    }

                    do {
                        let item = try await documentState.runtimeEngine.exportInterface(
                            for: object,
                            options: appDefaults.options
                        )
                        items.append(item)
                        succeeded += 1
                    } catch {
                        failed += 1
                    }
                }

                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    phaseText = "Writing files..."
                    progressValue = 1.0
                }

                try writeItems(items, to: directory)

                let duration = CFAbsoluteTimeGetCurrent() - startTime
                let objcCount = items.filter { !$0.isSwift }.count
                let swiftCount = items.filter { $0.isSwift }.count

                let result = ExportResult(
                    succeeded: succeeded,
                    failed: failed,
                    totalDuration: duration,
                    objcCount: objcCount,
                    swiftCount: swiftCount
                )

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    exportResult = result
                    currentPage = .completion
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    errorRelay.accept(error)
                }
            }
        }
    }

    private func writeItems(_ items: [RuntimeInterfaceExportItem], to directory: URL) throws {
        let objcItems = items.filter { !$0.isSwift }
        let swiftItems = items.filter { $0.isSwift }

        if !objcItems.isEmpty {
            let reporter = RuntimeInterfaceExportReporter()
            switch exportingState.objcFormat {
            case .singleFile:
                try RuntimeInterfaceExportWriter.writeSingleFile(
                    items: objcItems,
                    to: directory,
                    imageName: exportingState.imageName,
                    reporter: reporter
                )
            case .directory:
                try RuntimeInterfaceExportWriter.writeDirectory(
                    items: objcItems,
                    to: directory,
                    reporter: reporter
                )
            }
        }

        if !swiftItems.isEmpty {
            let reporter = RuntimeInterfaceExportReporter()
            switch exportingState.swiftFormat {
            case .singleFile:
                try RuntimeInterfaceExportWriter.writeSingleFile(
                    items: swiftItems,
                    to: directory,
                    imageName: exportingState.imageName,
                    reporter: reporter
                )
            case .directory:
                try RuntimeInterfaceExportWriter.writeDirectory(
                    items: swiftItems,
                    to: directory,
                    reporter: reporter
                )
            }
        }
    }
}
